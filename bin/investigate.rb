#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative '../lib/page_comparison'

# Page investigation tool for manual verification
class PageInvestigator
  include PageComparison

  def initialize(case_dir, yours_pdf, theirs_pdf)
    @case_dir = case_dir
    @yours_pdf = yours_pdf
    @theirs_pdf = theirs_pdf
    @ocr_cache = {}
    @cache_dir = File.join(case_dir, 'ocr_cache')

    # Load page mappings
    @yours_mapping = load_page_mapping(
      File.join(case_dir, 'mappings', 'yours_mapping.json')
    )
    @theirs_mapping = load_page_mapping(
      File.join(case_dir, 'mappings', 'theirs_mapping.json')
    )

    # Load TOC data
    reconciliation_file = File.join(case_dir, 'reports', 'reconciliation_data.json')
    if File.exist?(reconciliation_file)
      data = JSON.parse(File.read(reconciliation_file), symbolize_names: true)
      @yours_toc = (data[:yours_only] || []) + (data[:same_dates] || []).map { |e| e.merge(pages: e[:your_pages]) }
      @theirs_toc = (data[:theirs_only] || []) + (data[:same_dates] || []).map { |e| e.merge(pages: e[:their_pages]) }
    else
      @yours_toc = []
      @theirs_toc = []
    end
  end

  def auto_find_their_page(your_page)
    puts "Auto-searching for page #{your_page} in their PDF using red stamp..."

    # Use Python to search for the red stamp (faster than OCR)
    search_script = <<~PYTHON
      import fitz
      import re
      import sys

      doc = fitz.open('#{@theirs_pdf}')
      search_text = 'Actual Page No. #{your_page}'

      for page_num in range(len(doc)):
          page = doc[page_num]
          if page.search_for(search_text):
              # Found it! Verify by extracting the number
              text = page.get_text()
              match = re.search(r'Actual Page No\\.\\s*(\\d+)', text)
              if match and match.group(1) == '#{your_page}':
                  print(page_num + 1)  # Convert to 1-indexed
                  sys.exit(0)

      # Not found
      print('NOT_FOUND')
    PYTHON

    result = `python3 -c "#{search_script}"`.strip

    if result == 'NOT_FOUND'
      nil
    else
      result.to_i
    end
  end

  def investigate(your_page, their_physical_page = nil)
    # Auto-find if their_physical_page not provided
    if their_physical_page.nil?
      puts "=== Investigation: Your page #{your_page} (auto-finding in their PDF) ==="
      puts
      their_physical_page = auto_find_their_page(your_page)

      if their_physical_page
        puts "  ✓ Found at their physical page #{their_physical_page}"
        puts
      else
        puts "  ✗ Red stamp 'Actual Page No. #{your_page}' not found"
        puts "  Falling back to content search across their indexed pages..."
        puts
        investigate_by_content_search(your_page)
        return
      end
    else
      puts "=== Investigation: Your page #{your_page} vs Their physical page #{their_physical_page} ==="
    end
    puts

    # Check your page and OCR it
    your_physical = logical_to_physical(@yours_mapping, your_page)
    puts "Your page #{your_page}#{your_physical ? " (maps to physical page #{your_physical})" : ""}:"
    your_entry = find_entry_by_page(@yours_toc, your_page)
    if your_entry
      puts "  Date: #{your_entry[:date]}"
      puts "  Header (from TOC): #{your_entry[:header]}"
      puts "  In your TOC: YES"
    else
      puts "  In your TOC: NO"
    end

    # Extract and show preview of YOUR page
    your_text = extract_your_page_text(your_page)
    if your_text && !your_text.strip.empty?
      preview = your_text.strip.lines.first(5).join.strip[0..200]
      puts "  OCR from PDF physical page #{your_physical}: #{preview}..."
    else
      puts "  OCR Preview: (no text extracted from physical page #{your_physical})"
    end
    puts

    # OCR their page to show preview
    their_text = extract_their_physical_page_text(their_physical_page)

    # Check if their physical page is in TOC (search all entries)
    puts "Their physical page #{their_physical_page}:"
    their_toc_entry = find_their_toc_entry_by_physical(their_physical_page)
    if their_toc_entry
      puts "  In their TOC: YES"
      puts "  Date: #{their_toc_entry[:date]}"
      puts "  Header: #{their_toc_entry[:header]}"
    else
      puts "  In their TOC: NO (not indexed by vendor)"
    end

    # Show preview of their page content
    if their_text && !their_text.strip.empty?
      preview = their_text.strip.lines.first(5).join.strip[0..200]
      puts "  OCR Preview: #{preview}..."
    else
      puts "  OCR Preview: (no text extracted)"
    end
    puts

    # OCR comparison
    puts "OCR Comparison:"

    if your_text.nil?
      puts "  ERROR: Your page #{your_page} not found in mapping"
      return
    end

    if their_text.nil? || their_text.strip.empty?
      puts "  ERROR: Could not extract text from their physical page #{their_physical_page}"
      return
    end

    # Compare the two pages
    your_fp = create_fingerprint(your_text)
    their_fp = create_fingerprint(their_text)
    score = calculate_similarity(your_fp, their_fp)
    confidence = categorize_confidence(score)

    puts "  Your #{your_page} vs Their physical #{their_physical_page}: #{(score * 100).round(1)}% match"
    puts "  → #{confidence}"
    puts

    # Duplicate check (only if their page is not in TOC)
    unless their_toc_entry
      puts "Duplicate Check:"
      puts "  Comparing Their physical #{their_physical_page} to all their indexed pages..."
      check_for_duplicates(their_physical_page, their_text, their_fp)
    end

    # Conclusion
    puts
    puts "Conclusion:"
    if score > 0.8
      if their_toc_entry
        puts "  - Pages match (#{(score * 100).round(0)}% similar)"
        puts "  - Their physical page #{their_physical_page} IS indexed in their TOC"
      else
        puts "  - Vendor has the page but didn't index it separately"
        puts "  - ACTION: Add to discrepancy report as MISSING FROM VENDOR TOC"
      end
    elsif score > 0.5
      puts "  - Pages are likely the same document (#{(score * 100).round(0)}% similar)"
      puts "  - ACTION: Verify visually"
    else
      puts "  - Pages appear to be different documents (#{(score * 100).round(0)}% similar)"
      puts "  - ACTION: Review manually"
    end
  end

  def investigate_by_content_search(your_page)
    # Extract YOUR page content
    your_text = extract_your_page_text(your_page)
    if your_text.nil?
      puts "ERROR: Your page #{your_page} not found in mapping"
      return
    end

    your_entry = find_entry_by_page(@yours_toc, your_page)
    puts "Your page #{your_page}:"
    if your_entry
      puts "  Date: #{your_entry[:date]}"
      puts "  Header (from TOC): #{your_entry[:header]}"
    end
    puts

    puts "Searching their indexed pages for content match..."
    your_fp = create_fingerprint(your_text)

    # Search all their indexed pages
    all_their_logical_pages = @theirs_toc.flat_map { |e| e[:pages] }.compact.uniq.sort
    matches = []

    all_their_logical_pages.each do |logical_page|
      physical_page = logical_to_physical(@theirs_mapping, logical_page)
      next if physical_page.nil?

      # Extract text from their indexed page
      cache_key = "#{File.basename(@theirs_pdf)}:#{physical_page}"
      indexed_text = extract_page_text_ocr(@theirs_pdf, physical_page, cache_key, cache_dir: @cache_dir, cache: @ocr_cache)
      next if indexed_text.nil? || indexed_text.strip.empty?

      indexed_fp = create_fingerprint(indexed_text)
      score = calculate_similarity(your_fp, indexed_fp)

      if score > 0.5
        entry = find_entry_by_page(@theirs_toc, logical_page)
        matches << {
          logical_page: logical_page,
          physical_page: physical_page,
          score: score,
          date: entry&.dig(:date),
          header: entry&.dig(:header)
        }
      end
    end

    puts
    if matches.any?
      # Show top 3 matches
      puts "Best matches:"
      matches.sort_by { |m| -m[:score] }.first(3).each do |match|
        confidence = categorize_confidence(match[:score])
        header_preview = match[:header].to_s[0..60]
        puts "  → Their page #{match[:logical_page]} (physical #{match[:physical_page]}): #{(match[:score] * 100).round(0)}% - #{confidence}"
        puts "    Date: #{match[:date]}, #{header_preview}"
      end
      puts
      best = matches.max_by { |m| m[:score] }
      puts "Conclusion:"
      puts "  - Possibly matches their indexed page #{best[:logical_page]} (#{(best[:score] * 100).round(0)}% similar)"
      puts "  - ACTION: Verify visually at their physical page #{best[:physical_page]}"
    else
      puts "No matches found"
      puts
      puts "Conclusion:"
      puts "  - Not found in their PDF (neither by red stamp nor content match)"
      puts "  - ACTION: Likely MISSING FROM VENDOR"
    end
  end

  private

  # Find TOC entry by physical page number (reverse lookup through mapping)
  def find_their_toc_entry_by_physical(physical_page)
    # Find logical page(s) that map to this physical page
    logical_pages = @theirs_mapping.select { |_logical, phys| phys == physical_page }.keys

    # Find TOC entry containing any of these logical pages
    logical_pages.each do |logical_page|
      entry = find_entry_by_page(@theirs_toc, logical_page)
      return entry if entry
    end

    nil
  end

  # Extract text from YOUR page (uses mapping)
  def extract_your_page_text(logical_page)
    physical_page = logical_to_physical(@yours_mapping, logical_page)
    return nil if physical_page.nil?

    cache_key = "#{File.basename(@yours_pdf)}:logical_#{logical_page}"
    extract_page_text_ocr(@yours_pdf, physical_page, cache_key, cache_dir: @cache_dir, cache: @ocr_cache)
  end

  # Extract text from THEIR physical page (no mapping)
  def extract_their_physical_page_text(physical_page)
    cache_key = "#{File.basename(@theirs_pdf)}:physical_#{physical_page}"
    extract_page_text_ocr(@theirs_pdf, physical_page, cache_key, cache_dir: @cache_dir, cache: @ocr_cache)
  end

  def check_for_duplicates(their_physical_page, their_text, their_fp)
    # Get all logical pages from their TOC and convert to physical
    all_their_logical_pages = @theirs_toc.flat_map { |e| e[:pages] }.compact.uniq.sort

    # Compare against each indexed page
    matches = []
    all_their_logical_pages.each do |logical_page|
      physical_page = logical_to_physical(@theirs_mapping, logical_page)
      next if physical_page.nil? || physical_page == their_physical_page

      # Extract text from their indexed page
      cache_key = "#{File.basename(@theirs_pdf)}:#{physical_page}"
      indexed_text = extract_page_text_ocr(@theirs_pdf, physical_page, cache_key, cache_dir: @cache_dir, cache: @ocr_cache)
      next if indexed_text.nil? || indexed_text.strip.empty?

      indexed_fp = create_fingerprint(indexed_text)
      score = calculate_similarity(their_fp, indexed_fp)

      # Only flag very high matches (98%+) to avoid false positives from same-provider boilerplate
      if score > 0.98
        entry = find_entry_by_page(@theirs_toc, logical_page)
        matches << {
          logical_page: logical_page,
          physical_page: physical_page,
          score: score,
          date: entry&.dig(:date),
          header: entry&.dig(:header)
        }
      end
    end

    if matches.any?
      # Show high-confidence duplicates only
      puts "  High-confidence duplicates found (98%+ match):"
      matches.sort_by { |m| -m[:score] }.first(3).each do |match|
        header_preview = match[:header].to_s[0..50]
        puts "    → Their page #{match[:logical_page]} (physical #{match[:physical_page]}): #{(match[:score] * 100).round(1)}%"
        puts "      #{match[:date]}, #{header_preview}"
      end
      puts "  → LIKELY DUPLICATE - Verify if same document"
    else
      puts "  → No high-confidence duplicates found (checked their indexed pages)"
    end
  end
end

# Main execution
if __FILE__ == $0
  options = {}
  OptionParser.new do |opts|
    opts.banner = "Page Investigation Tool\n\n"
    opts.banner += "Usage: #{$0} --case CASE_NAME --yours PAGE [--theirs-physical PAGE] [YOURS_PDF] [THEIRS_PDF]"

    opts.on("--case NAME", "Case name") do |name|
      options[:case_name] = name
    end

    opts.on("--yours PAGE", Integer, "Your page number (logical)") do |page|
      options[:yours] = page
    end

    opts.on("--theirs-physical PAGE", Integer, "Their physical page number (optional - will auto-find if not provided)") do |page|
      options[:theirs_physical] = page
    end

    opts.on("-h", "--help", "Show this help message") do
      puts opts
      puts "\nArguments:"
      puts "  YOURS_PDF     Path to your indexed PDF (optional if in current directory)"
      puts "  THEIRS_PDF    Path to vendor's indexed PDF (optional if in current directory)"
      puts
      puts "Examples:"
      puts "  # Auto-find mode (recommended):"
      puts "  cd ~/Downloads/Record\\ Reviews\\ Files/Equity\\ Evaluations/Isidro\\ Reyes"
      puts "  #{$0} --case \"Isidro Reyes\" --yours 304"
      puts
      puts "  # Manual mode (when you already know their physical page):"
      puts "  #{$0} --case \"Isidro Reyes\" --yours 304 --theirs-physical 154"
      puts
      puts "How it works:"
      puts "  1. Auto-find: Searches their PDF for red stamp 'Actual Page No. 304'"
      puts "  2. If found → OCR compares your page vs their page"
      puts "  3. If not found → Searches their indexed pages for content match"
      puts "  4. Reports match confidence and recommendations"
      puts
      puts "Options:"
      puts "  --yours 304           = logical page from YOUR TOC"
      puts "  --theirs-physical 154 = (optional) skip auto-find, use this physical page"
      puts
      puts "Match Thresholds:"
      puts "  > 80%: SAME DOCUMENT"
      puts "  50-80%: LIKELY SAME (verify visually)"
      puts "  < 50%: DIFFERENT DOCUMENTS"
      exit 0
    end
  end.parse!

  # Validate options
  if !options[:case_name] || !options[:yours]
    puts "Error: Missing required options (--case and --yours)"
    puts "Run with --help for usage information"
    exit 1
  end

  # Build paths
  script_dir = File.dirname(File.absolute_path(__FILE__))
  repo_root = File.dirname(script_dir)
  case_dir = File.join(repo_root, "cases", options[:case_name])

  unless Dir.exist?(case_dir)
    puts "Error: Case directory not found: #{case_dir}"
    puts "Available cases:"
    Dir.glob(File.join(repo_root, "cases", "*")).each do |dir|
      puts "  - #{File.basename(dir)}"
    end
    exit 1
  end

  # Get PDF paths from arguments or current directory
  if ARGV.length >= 2
    yours_pdf = File.absolute_path(ARGV[0])
    theirs_pdf = File.absolute_path(ARGV[1])
  else
    # Auto-detect in current directory
    yours_pdf = Dir.glob("*.pdf").find { |f| f.match?(/medical_summary/i) }
    theirs_pdf = Dir.glob("*.pdf").find { |f| f.match?(/COMPLETE/i) }

    yours_pdf = File.absolute_path(yours_pdf) if yours_pdf
    theirs_pdf = File.absolute_path(theirs_pdf) if theirs_pdf
  end

  unless yours_pdf && File.exist?(yours_pdf)
    puts "Error: Your PDF not found"
    puts "Current directory: #{Dir.pwd}"
    puts "Available PDFs:"
    Dir.glob("*.pdf").each { |f| puts "  - #{f}" }
    exit 1
  end

  unless theirs_pdf && File.exist?(theirs_pdf)
    puts "Error: Their PDF not found"
    puts "Current directory: #{Dir.pwd}"
    puts "Available PDFs:"
    Dir.glob("*.pdf").each { |f| puts "  - #{f}" }
    exit 1
  end

  investigator = PageInvestigator.new(case_dir, yours_pdf, theirs_pdf)
  investigator.investigate(options[:yours], options[:theirs_physical])
end
