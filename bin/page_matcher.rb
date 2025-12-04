#!/usr/bin/env ruby
# frozen_string_literal: true

require 'csv'
require 'json'
require 'tempfile'

# Extract and compare page content to find matching pages across two PDFs
class PageContentMatcher
  def initialize(yours_pdf, theirs_pdf, yours_mapping: nil, theirs_mapping: nil, base_path: '.')
    @yours_pdf = yours_pdf
    @theirs_pdf = theirs_pdf
    @yours_cache = {}
    @theirs_cache = {}
    @ocr_cache = {}
    @base_path = base_path

    # Load page mappings (logical page -> physical page)
    @yours_mapping = yours_mapping || load_page_mapping('medical_summary_indexed_hyperlink_mapping.json')
    @theirs_mapping = theirs_mapping || load_page_mapping('COMPLETE_Reyes_Isidro_10_hyperlink_mapping.json')

    puts "Loaded #{@yours_mapping.size} mappings for YOUR PDF"
    puts "Loaded #{@theirs_mapping.size} mappings for THEIR PDF"
  end

  private

  def load_page_mapping(filename)
    mapping_file = "#{@base_path}/mappings/#{filename}"
    if File.exist?(mapping_file)
      JSON.parse(File.read(mapping_file)).transform_keys(&:to_i)
    else
      puts "Warning: No page mapping file found at #{mapping_file}"
      puts "Using logical page numbers directly (may be incorrect!)"
      {}
    end
  end

  public

  # Convert logical page to physical page for YOUR PDF
  def your_logical_to_physical(logical_page)
    @yours_mapping[logical_page]
  end

  # Convert logical page to physical page for THEIR PDF (direct mapping)
  # Returns nil if page not in mapping (no fallback)
  def their_logical_to_physical(logical_page)
    @theirs_mapping[logical_page]
  end

  # Find the best matching page in their PDF for a given page in yours
  # Returns { page: X, score: Y } or { not_in_document: true } or { not_in_toc: true }
  def find_matching_page(your_page_num)
    your_text = extract_page_text(@yours_pdf, your_page_num)

    # Page doesn't exist in your mapping
    if your_text.nil?
      return { not_in_document: true }
    end

    return nil if your_text.strip.empty?

    # Check if same logical page exists in their PDF mapping
    unless @theirs_mapping.key?(your_page_num)
      # Not in their TOC - don't search randomly, flag for manual review
      return { not_in_toc: true }
    end

    # Same logical page exists - compare via OCR
    their_text = extract_page_text_cached(@theirs_pdf, your_page_num)
    if their_text.nil? || their_text.strip.empty?
      return { not_in_toc: true }
    end

    your_fingerprint = create_fingerprint(your_text)
    their_fingerprint = create_fingerprint(their_text)
    score = calculate_similarity(your_fingerprint, their_fingerprint)

    { page: your_page_num, score: score }
  end

  # Find the best matching page in your PDF for a given page in theirs
  # Returns { page: X, score: Y } or { not_in_document: true } or { not_in_toc: true }
  def find_matching_page_reverse(their_page_num)
    their_text = extract_page_text(@theirs_pdf, their_page_num)

    # Page doesn't exist in mapping
    if their_text.nil?
      return { not_in_document: true }
    end

    return nil if their_text.strip.empty?

    # Check if same logical page exists in your PDF mapping
    unless @yours_mapping.key?(their_page_num)
      # Not in your TOC - flag for manual review
      return { not_in_toc: true }
    end

    # Same logical page exists - compare via OCR
    your_text = extract_page_text(@yours_pdf, their_page_num)
    if your_text.nil? || your_text.strip.empty?
      return { not_in_toc: true }
    end

    their_fingerprint = create_fingerprint(their_text)
    your_fingerprint = create_fingerprint(your_text)
    score = calculate_similarity(their_fingerprint, your_fingerprint)

    { page: their_page_num, score: score }
  end

  private

  # Extract text from a specific page using OCR
  def extract_page_text_ocr(pdf_path, physical_page)
    # Check OCR cache first
    cache_key = "#{File.basename(pdf_path)}:#{physical_page}"
    return @ocr_cache[cache_key] if @ocr_cache.key?(cache_key)

    # Check disk cache
    cache_dir = "#{@base_path}/ocr_cache"
    Dir.mkdir(cache_dir) unless Dir.exist?(cache_dir)
    cache_file = "#{cache_dir}/#{cache_key.gsub(':', '_')}.txt"

    if File.exist?(cache_file)
      text = File.read(cache_file)
      @ocr_cache[cache_key] = text
      return text
    end

    # Run OCR
    pdf_name = File.basename(pdf_path, '.*')
    puts "    OCR: #{pdf_name} page #{physical_page}..."
    temp_img = "#{cache_dir}/temp_#{cache_key.gsub(':', '_')}.png"
    begin
      # Convert PDF page to image
      system("mutool", "draw", "-o", temp_img, "-r", "150", pdf_path, physical_page.to_s, out: File::NULL, err: File::NULL)

      # Run OCR
      text = `tesseract "#{temp_img}" stdout 2>/dev/null`.force_encoding('UTF-8').scrub('?')

      # Cache the result
      File.write(cache_file, text)
      @ocr_cache[cache_key] = text

      text
    rescue => e
      puts "OCR error for #{pdf_path} page #{physical_page}: #{e.message}"
      ""
    ensure
      File.delete(temp_img) if File.exist?(temp_img)
    end
  end

  # Extract text from a specific page of a PDF (with logical->physical conversion)
  # Returns nil if page doesn't exist in mapping
  def extract_page_text(pdf_path, logical_page)
    # Convert logical to physical - do NOT fall back to logical page
    physical_page = if pdf_path == @yours_pdf
      @yours_mapping[logical_page]
    else
      @theirs_mapping[logical_page]
    end

    return nil if physical_page.nil?

    extract_page_text_ocr(pdf_path, physical_page)
  end

  # Extract with caching
  def extract_page_text_cached(pdf_path, logical_page)
    cache = (pdf_path == @yours_pdf) ? @yours_cache : @theirs_cache
    cache[logical_page] ||= extract_page_text(pdf_path, logical_page)
  end

  # Get the total page count of a PDF
  def get_pdf_page_count(pdf_path)
    output = `mutool info "#{pdf_path}" 2>&1`
    if match = output.match(/Pages:\s+(\d+)/)
      match[1].to_i
    else
      500 # Default max for safety
    end
  end

  # Create a fingerprint from page text
  def create_fingerprint(text)
    normalized = text.downcase.gsub(/\s+/, ' ').strip

    # Extract dates (MM/DD/YYYY or variations)
    dates = normalized.scan(/\d{1,2}\/\d{1,2}\/\d{2,4}/)

    # Extract potential provider names (words followed by MD, DO, PA, etc.)
    providers = normalized.scan(/\w+(?:,?\s+(?:md|do|pa|np|dc|dds|phd|psyd))/i)

    # Extract first 200 characters as base fingerprint
    preview = normalized[0..200] || ""

    # Extract key medical terms
    medical_terms = normalized.scan(/(?:office visit|x-ray|mri|therapy|report|encounter|consultation|examination|treatment)/)

    {
      preview: preview,
      dates: dates.uniq,
      providers: providers.uniq,
      medical_terms: medical_terms.uniq,
      full_text: normalized
    }
  end

  # Calculate similarity between two fingerprints
  def calculate_similarity(fp1, fp2)
    scores = []

    # Date overlap
    if !fp1[:dates].empty? && !fp2[:dates].empty?
      date_overlap = (fp1[:dates] & fp2[:dates]).size.to_f / [fp1[:dates].size, fp2[:dates].size].max
      scores << date_overlap * 3.0 # Weight dates heavily
    end

    # Provider overlap
    if !fp1[:providers].empty? && !fp2[:providers].empty?
      provider_overlap = (fp1[:providers] & fp2[:providers]).size.to_f / [fp1[:providers].size, fp2[:providers].size].max
      scores << provider_overlap * 2.0 # Weight providers heavily
    end

    # Preview text similarity (simple character overlap)
    preview_similarity = text_overlap(fp1[:preview], fp2[:preview])
    scores << preview_similarity

    # Medical terms overlap
    if !fp1[:medical_terms].empty? && !fp2[:medical_terms].empty?
      terms_overlap = (fp1[:medical_terms] & fp2[:medical_terms]).size.to_f / [fp1[:medical_terms].size, fp2[:medical_terms].size].max
      scores << terms_overlap
    end

    # Full text similarity (for final check)
    full_similarity = text_overlap(fp1[:full_text][0..500], fp2[:full_text][0..500])
    scores << full_similarity * 2.0

    return 0.0 if scores.empty?

    scores.sum / scores.size
  end

  # Calculate text overlap using a simple character-based approach
  def text_overlap(text1, text2)
    return 0.0 if text1.empty? || text2.empty?

    # Tokenize into words
    words1 = text1.split
    words2 = text2.split

    return 0.0 if words1.empty? || words2.empty?

    # Calculate Jaccard similarity
    intersection = (words1 & words2).size.to_f
    union = (words1 | words2).size.to_f

    union > 0 ? intersection / union : 0.0
  end
end

# Generate final discrepancy report
class DiscrepancyReporter
  def initialize(reconciliation_data, matcher)
    @data = reconciliation_data
    @matcher = matcher
  end

  def generate_report(output_path)
    CSV.open(output_path, "wb") do |csv|
      csv << ["Status", "Your Date", "Their Date", "Your Pages", "Their Match Pages", "Match Confidence", "Your Header", "Their Header", "Action"]

      # Process YOURS ONLY entries
      puts "\nProcessing YOURS ONLY entries (#{@data['yours_only'].size})..."
      @data['yours_only'].each_with_index do |entry, idx|
        print "  #{idx + 1}/#{@data['yours_only'].size}... "

        # Skip filtered entries that aren't in their TOC
        # Both sides likely filtered the same routine content
        header = entry['header'].to_s
        if header.include?('[FILTERED]')
          first_page_check = @matcher.find_matching_page(entry['pages'].first)
          if first_page_check.nil? || first_page_check[:not_in_toc]
            puts "⊘ (filtered, not in their TOC - skipped)"
            next
          end
        end

        # Check if page exists in your document
        first_page_result = @matcher.find_matching_page(entry['pages'].first)
        if first_page_result && first_page_result[:not_in_document]
          csv << [
            "YOURS ONLY",
            entry['date'],
            "—",
            entry['pages'].join(", "),
            "—",
            "NOT IN YOUR DOCUMENT",
            entry['header'],
            "—",
            "Page not found in your PDF TOC"
          ]
          puts "⊘ (not in document)"
          next
        end

        # Check if page exists in their TOC
        if first_page_result && first_page_result[:not_in_toc]
          csv << [
            "YOURS ONLY",
            entry['date'],
            "—",
            entry['pages'].join(", "),
            "—",
            "NOT IN THEIR TOC",
            entry['header'],
            "—",
            "MANUAL REVIEW NEEDED"
          ]
          puts "⊘ (not in their TOC)"
          next
        end

        # Try to find matching pages in their document
        match_results = entry['pages'].map do |page|
          result = @matcher.find_matching_page(page)
          result && !result[:not_in_document] && !result[:not_in_toc] ? { page: page, match: result } : nil
        end.compact

        if match_results.any?
          # Find best match
          best = match_results.max_by { |r| r[:match][:score] }
          similarity_pct = (best[:match][:score] * 100).round(1)
          confidence = categorize_confidence(best[:match][:score])
          action = generate_action("YOURS ONLY", confidence, best[:match][:page])

          csv << [
            "YOURS ONLY",
            entry['date'],
            "—",
            entry['pages'].join(", "),
            best[:match][:page],
            confidence,
            entry['header'],
            "—",
            action
          ]
          puts "✓ (#{similarity_pct}%)"
        else
          csv << [
            "YOURS ONLY",
            entry['date'],
            "—",
            entry['pages'].join(", "),
            "—",
            "NO MATCH",
            entry['header'],
            "—",
            "MISSING FROM VENDOR"
          ]
          puts "✗ (no match)"
        end
      end

      # Process THEIRS ONLY entries
      puts "\nProcessing THEIRS ONLY entries (#{@data['theirs_only'].size})..."
      @data['theirs_only'].each_with_index do |entry, idx|
        print "  #{idx + 1}/#{@data['theirs_only'].size}... "

        # Skip entries with no pages (invalid TOC entries)
        if entry['pages'].nil? || entry['pages'].empty?
          puts "⊘ (no pages - skipped)"
          next
        end

        # Check if page exists in their document
        first_page_result = @matcher.find_matching_page_reverse(entry['pages'].first)
        if first_page_result && first_page_result[:not_in_document]
          csv << [
            "THEIRS ONLY",
            "—",
            entry['date'],
            "—",
            entry['pages'].join(", "),
            "NOT IN THEIR DOCUMENT",
            "—",
            entry['header'],
            "Page not found in their PDF TOC"
          ]
          puts "⊘ (not in document)"
          next
        end

        # Check if page exists in your TOC
        if first_page_result && first_page_result[:not_in_toc]
          csv << [
            "THEIRS ONLY",
            "—",
            entry['date'],
            "—",
            entry['pages'].join(", "),
            "NOT IN YOUR TOC",
            "—",
            entry['header'],
            "MANUAL REVIEW NEEDED"
          ]
          puts "⊘ (not in your TOC)"
          next
        end

        # Try to find matching pages in your document
        match_results = entry['pages'].map do |page|
          result = @matcher.find_matching_page_reverse(page)
          result && !result[:not_in_document] && !result[:not_in_toc] ? { page: page, match: result } : nil
        end.compact

        if match_results.any?
          # Find best match
          best = match_results.max_by { |r| r[:match][:score] }
          similarity_pct = (best[:match][:score] * 100).round(1)
          confidence = categorize_confidence(best[:match][:score])
          action = generate_action("THEIRS ONLY", confidence, best[:match][:page])

          csv << [
            "THEIRS ONLY",
            "—",
            entry['date'],
            best[:match][:page],
            entry['pages'].join(", "),
            confidence,
            "—",
            entry['header'],
            action
          ]
          puts "✓ (#{similarity_pct}%)"
        else
          csv << [
            "THEIRS ONLY",
            "—",
            entry['date'],
            "—",
            entry['pages'].join(", "),
            "NO MATCH",
            "—",
            entry['header'],
            "MISSING FROM YOURS"
          ]
          puts "✗ (no match)"
        end
      end

      # Process SAME DATE entries (both TOCs have this date)
      puts "\nProcessing SAME DATE entries (#{@data['same_dates'].size})..."
      @data['same_dates'].each_with_index do |entry, idx|
        print "  #{idx + 1}/#{@data['same_dates'].size}... "

        csv << [
          "SAME DATE",
          entry['date'],
          entry['date'],
          entry['your_pages'].join(", "),
          entry['their_pages'].join(", "),
          "EXACT DATE MATCH",
          entry['your_header'],
          entry['their_header'],
          "Compare page counts and headers"
        ]
        puts "✓"
      end
    end
  end

  private

  def categorize_confidence(score)
    if score > 0.7
      "STRONG (#{(score * 100).round(0)}%)"
    elsif score > 0.5
      "LIKELY (#{(score * 100).round(0)}%)"
    elsif score > 0.3
      "WEAK (#{(score * 100).round(0)}%)"
    else
      "NO MATCH"
    end
  end

  def generate_action(status, confidence, match_page)
    case status
    when "YOURS ONLY"
      if confidence.start_with?("STRONG")
        "VERIFY MATCH - CHECK THEIR PAGE #{match_page}"
      elsif confidence.start_with?("LIKELY")
        "CHECK THEIR PAGE #{match_page}"
      elsif confidence.start_with?("WEAK")
        "CHECK THEIR PAGE #{match_page}"
      else
        "MISSING FROM VENDOR"
      end
    when "THEIRS ONLY"
      if confidence.start_with?("STRONG")
        "VERIFY MATCH - CHECK YOUR PAGE #{match_page}"
      elsif confidence.start_with?("LIKELY")
        "CHECK YOUR PAGE #{match_page}"
      elsif confidence.start_with?("WEAK")
        "CHECK YOUR PAGE #{match_page}"
      else
        "MISSING FROM YOURS"
      end
    else
      "DATE DISCREPANCY"
    end
  end
end

# Main execution
if __FILE__ == $0
  if ARGV.length != 4
    puts "Usage: #{$0} <case_dir> <reconciliation_data.json> <your_indexed.pdf> <their_indexed.pdf>"
    puts "\nExample:"
    puts "  #{$0} ~/git/auditor/cases/Reyes_Isidro reconciliation_data.json yours.pdf theirs.pdf"
    exit 1
  end

  case_dir = ARGV[0]
  json_file = ARGV[1]
  yours_pdf = ARGV[2]
  theirs_pdf = ARGV[3]

  unless File.exist?(json_file)
    puts "Error: Reconciliation data not found: #{json_file}"
    exit 1
  end

  unless File.exist?(yours_pdf)
    puts "Error: Your PDF not found: #{yours_pdf}"
    exit 1
  end

  unless File.exist?(theirs_pdf)
    puts "Error: Their PDF not found: #{theirs_pdf}"
    exit 1
  end

  # Load reconciliation data
  puts "Loading reconciliation data..."
  reconciliation_data = JSON.parse(File.read(json_file, encoding: 'UTF-8'))

  # Initialize page matcher
  puts "Initializing page content matcher..."
  matcher = PageContentMatcher.new(yours_pdf, theirs_pdf, base_path: case_dir)

  # Generate report
  output_path = File.join(case_dir, "reports", "discrepancy_report.csv")

  reporter = DiscrepancyReporter.new(reconciliation_data, matcher)
  reporter.generate_report(output_path)

  puts "\n✓ Discrepancy report saved to: #{output_path}"
end
