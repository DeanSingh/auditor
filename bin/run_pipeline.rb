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

    # Phase 0: Build page mappings (if not exist)
    run_phase("Phase 0: Building page mappings") do
      your_basename = File.basename(@your_indexed, '.*')
      their_basename = File.basename(@their_indexed, '.*')

      mapping_files = [
        File.join(@case_dir, "mappings", "#{your_basename}_hyperlink_mapping.json"),
        File.join(@case_dir, "mappings", "#{their_basename}_hyperlink_mapping.json")
      ]

      if mapping_files.all? { |f| File.exist?(f) }
        puts "  (Mapping files already exist, skipping)"
        true
      else
        puts "  Creating page mappings..."
        system("python", File.join(@bin_dir, "build_complete_mappings.py"),
               @case_dir, @your_indexed, @their_indexed)
      end
    end

    # Phase 1: SKIPPED - compare_docs.rb
    puts "Phase 1: Skipped (compare_docs.rb - record review content in TOC)"
    puts

    # Phase 2: Compare TOCs
    run_phase("Phase 2: Reconciling TOCs") do
      system(File.join(@bin_dir, "simple_reconcile.rb"),
             @case_dir, @your_indexed, @their_indexed)
    end

    # Phase 3: Convert to PDF (BEFORE page matching - page_matcher needs PDFs!)
    # Always convert to ensure latest version of DOCX is used
    run_phase("Phase 3: Converting Word document to PDF") do
      if @your_indexed.end_with?('.docx')
        pdf_file = @your_indexed.gsub(/\.docx$/i, '.pdf')
        print "  Converting #{File.basename(@your_indexed)}... "

        if convert_to_pdf(@your_indexed, pdf_file)
          puts "✓"
          true
        else
          puts "✗ (failed)"
          false
        end
      else
        puts "  (No DOCX file, skipping conversion)"
        true
      end
    end

    # Phase 4: Match pages by content similarity (AFTER PDF conversion)
    run_phase("Phase 4: Matching pages by content similarity") do
      # Use PDF version of your indexed doc
      your_indexed_pdf = @your_indexed.gsub(/\.docx$/i, '.pdf')
      reconciliation_json = File.join(@case_dir, "reports", "reconciliation_data.json")
      system(File.join(@bin_dir, "page_matcher.rb"),
             @case_dir, reconciliation_json, your_indexed_pdf, @their_indexed)
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
      puts "  Phase 0: Build page mappings"
      puts "  Phase 1: SKIPPED (compare_docs.rb - record review content in TOC)"
      puts "  Phase 2: Reconcile TOCs (simple_reconcile.rb)"
      puts "  Phase 3: Convert Word document to PDF (if needed)"
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
