#!/usr/bin/env ruby
# frozen_string_literal: true

require 'time'

# Master pipeline for medical records processing
class MedicalRecordsPipeline
  def initialize(case_dir, your_indexed, their_indexed)
    @case_dir = case_dir
    @start_time = Time.now
    @your_indexed = your_indexed
    @their_indexed = their_indexed
    @bin_dir = File.join(File.dirname(File.absolute_path(__FILE__)))
  end

  def run
    puts "=== Medical Records Processing Pipeline ==="
    puts

    # Phase 1: Convert DOCX to PDF (if needed)
    run_phase("Phase 1: Converting to PDF") do
      if @your_indexed.end_with?('.docx')
        @your_pdf = @your_indexed.gsub(/\.docx$/i, '.pdf')
        print "  Converting #{File.basename(@your_indexed)}... "

        if convert_to_pdf(@your_indexed, @your_pdf)
          puts "✓"
          true
        else
          puts "✗ (failed)"
          false
        end
      else
        @your_pdf = @your_indexed
        puts "  (Already PDF, skipping conversion)"
        true
      end
    end

    # Phase 2: Build page mappings from hyperlinks
    run_phase("Phase 2: Building page mappings") do
      yours_mapping = File.join(@case_dir, "mappings", "yours_mapping.json")
      theirs_mapping = File.join(@case_dir, "mappings", "theirs_mapping.json")

      # Always rebuild yours (TOC changes)
      puts "  Building YOUR mapping..."
      success1 = system("python", File.join(@bin_dir, "extract_hyperlinks.py"),
                        @your_pdf, "--output", yours_mapping)

      # Cache theirs (doesn't change)
      if File.exist?(theirs_mapping)
        puts "  (THEIR mapping cached, skipping)"
        success2 = true
      else
        puts "  Building THEIR mapping..."
        success2 = system("python", File.join(@bin_dir, "extract_hyperlinks.py"),
                          @their_indexed, "--output", theirs_mapping)
      end

      success1 && success2
    end

    # Phase 3: Reconcile TOCs
    run_phase("Phase 3: Reconciling TOCs") do
      system(File.join(@bin_dir, "simple_reconcile.rb"),
             @case_dir, @your_indexed, @their_indexed)
    end

    # Phase 4: Match pages by content similarity
    run_phase("Phase 4: Matching pages by content similarity") do
      reconciliation_json = File.join(@case_dir, "reports", "reconciliation_data.json")
      system(File.join(@bin_dir, "page_matcher.rb"),
             @case_dir, reconciliation_json, @your_pdf, @their_indexed, @your_indexed)
    end

    elapsed = Time.now - @start_time
    puts
    puts "=== Pipeline complete in #{elapsed.round(1)} seconds ==="
  end

  private

  def run_phase(description, &block)
    puts "#{description}..."

    success = block.call

    if success
      puts "✓ #{description.split(':').first} complete"
    else
      puts "✗ #{description.split(':').first} FAILED"
      puts
      puts "Pipeline stopped due to failure in #{description.split(':').first}"
      exit 1
    end

    puts
  end

  def convert_to_pdf(docx_file, pdf_file)
    # Try AppleScript with Microsoft Word (macOS)
    if mac_word_available?
      applescript = <<~APPLESCRIPT
        tell application "Microsoft Word"
          open "#{File.absolute_path(docx_file)}"
          set doc to active document
          save as doc file name "#{File.absolute_path(pdf_file)}" file format format PDF
          close doc
        end tell
      APPLESCRIPT

      system("osascript", "-e", applescript, out: File::NULL, err: File::NULL)
    elsif python_docx2pdf_available?
      # Try docx2pdf Python library
      system("docx2pdf", docx_file, pdf_file, out: File::NULL, err: File::NULL)
    else
      puts
      puts "  Error: No PDF conversion method available"
      puts "  Options:"
      puts "    1. Install Microsoft Word for Mac"
      puts "    2. Install docx2pdf: pip install docx2pdf"
      puts "    3. Manually convert #{docx_file} to PDF and re-run"
      false
    end
  end

  def mac_word_available?
    system("osascript", "-e", "tell application \"Microsoft Word\" to get name",
           out: File::NULL, err: File::NULL)
  end

  def python_docx2pdf_available?
    system("which", "docx2pdf", out: File::NULL, err: File::NULL)
  end
end

# Main execution
if __FILE__ == $0
  require 'optparse'

  # Parse options
  case_name = nil
  OptionParser.new do |opts|
    opts.banner = "Medical Records Processing Pipeline\n\n"
    opts.banner += "Usage: #{$0} [options] <your_indexed.docx|pdf> <their_indexed.pdf>"

    opts.on("--case NAME", "Case name (creates cases/NAME/ folder)") do |name|
      case_name = name
    end

    opts.on("-h", "--help", "Show this help message") do
      puts opts
      puts "\nArguments:"
      puts "  your_indexed.docx     Your indexed document (TOC + record review + source pages)"
      puts "  their_indexed.pdf     Vendor's indexed document (TOC + record review + source pages)"
      puts
      puts "Examples:"
      puts "  #{$0} --case \"Isidro_Reyes\" ~/Downloads/medical_summary_indexed.pdf ~/Downloads/COMPLETE_Reyes_Isidro_10.pdf"
      puts "  #{$0} /path/to/yours.pdf /path/to/COMPLETE_Reyes_Isidro_10.pdf  # Auto-detects case name"
      puts
      puts "This script orchestrates the medical records comparison workflow:"
      puts "  Phase 1: Convert Word document to PDF (if needed)"
      puts "  Phase 2: Build page mappings from hyperlinks (extract_hyperlinks.py)"
      puts "  Phase 3: Reconcile TOCs (simple_reconcile.rb)"
      puts "  Phase 4: Match pages by content similarity (page_matcher.rb)"
      puts
      puts "Output:"
      puts "  Cases are stored in: ~/git/auditor/cases/<case_name>/"
      puts "    - mappings/           Page mapping files"
      puts "    - reports/            Reconciliation and discrepancy reports"
      puts "    - ocr_cache/          OCR results cache"
      exit 0
    end
  end.parse!

  # Check arguments
  if ARGV.length != 2
    puts "Error: Expected 2 arguments (your_indexed and their_indexed files)"
    puts "Run with --help for usage information"
    exit 1
  end

  your_indexed = File.absolute_path(ARGV[0])
  their_indexed = File.absolute_path(ARGV[1])

  # Validate files exist
  [your_indexed, their_indexed].each do |file|
    unless File.exist?(file)
      puts "Error: File not found: #{file}"
      exit 1
    end
  end

  # Auto-detect case name if not provided
  if case_name.nil?
    # Try to extract from "COMPLETE_Name_Name_##.pdf" pattern
    if their_indexed =~ /COMPLETE[_\s]+([A-Za-z]+)[_\s]+([A-Za-z]+)[_\s]*\d*/i
      case_name = "#{$2}_#{$1}"  # LastName_FirstName
    else
      # Fallback to timestamp
      case_name = Time.now.strftime("Case_%Y%m%d_%H%M%S")
    end
    puts "Auto-detected case name: #{case_name}"
  end

  # Setup directories
  script_dir = File.dirname(File.absolute_path(__FILE__))
  repo_root = File.dirname(script_dir)  # Parent of bin/
  case_dir = File.join(repo_root, "cases", case_name)

  # Create case directories
  Dir.mkdir(case_dir) unless Dir.exist?(case_dir)
  %w[mappings reports ocr_cache].each do |subdir|
    dir_path = File.join(case_dir, subdir)
    Dir.mkdir(dir_path) unless Dir.exist?(dir_path)
  end

  puts "Case directory: #{case_dir}"
  puts

  pipeline = MedicalRecordsPipeline.new(case_dir, your_indexed, their_indexed)
  pipeline.run
end
