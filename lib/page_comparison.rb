# frozen_string_literal: true

# Shared page comparison utilities used by both PageContentMatcher and PageInvestigator.
# Provides text fingerprinting, similarity scoring, OCR extraction, and page mapping helpers.
module PageComparison
  # --- Page mapping ---

  def load_page_mapping(mapping_file)
    if File.exist?(mapping_file)
      JSON.parse(File.read(mapping_file)).transform_keys(&:to_i)
    else
      puts "Warning: No page mapping file found at #{mapping_file}"
      {}
    end
  end

  def logical_to_physical(mapping, logical_page)
    mapping[logical_page]
  end

  def find_entry_by_page(toc_entries, logical_page)
    toc_entries.find { |entry| entry[:pages]&.include?(logical_page) }
  end

  # --- OCR extraction ---

  def extract_page_text_ocr(pdf_path, physical_page, cache_key, cache_dir:, cache:)
    return cache[cache_key] if cache.key?(cache_key)

    Dir.mkdir(cache_dir) unless Dir.exist?(cache_dir)
    cache_file = "#{cache_dir}/#{cache_key.gsub(':', '_')}.txt"

    if File.exist?(cache_file)
      text = File.read(cache_file)
      cache[cache_key] = text
      return text
    end

    pdf_name = File.basename(pdf_path, '.*')
    puts "    OCR: #{pdf_name} page #{physical_page}..."
    temp_img = "#{cache_dir}/temp_#{cache_key.gsub(':', '_')}.png"

    begin
      system("mutool", "draw", "-o", temp_img, "-r", "150", pdf_path, physical_page.to_s, out: File::NULL, err: File::NULL)
      text = `tesseract "#{temp_img}" stdout 2>/dev/null`.force_encoding('UTF-8').scrub('?')

      File.write(cache_file, text)
      cache[cache_key] = text
      text
    rescue StandardError => e
      puts "OCR error for #{pdf_path} page #{physical_page}: #{e.message}"
      ""
    ensure
      File.delete(temp_img) if File.exist?(temp_img)
    end
  end

  # --- Fingerprinting & similarity ---

  def create_fingerprint(text)
    normalized = text.downcase.gsub(/\s+/, ' ').strip

    {
      preview: normalized[0..200] || "",
      dates: normalized.scan(/\d{1,2}\/\d{1,2}\/\d{2,4}/).uniq,
      providers: normalized.scan(/\w+(?:,?\s+(?:md|do|pa|np|dc|dds|phd|psyd))/i).uniq,
      medical_terms: normalized.scan(/(?:office visit|x-ray|mri|therapy|report|encounter|consultation|examination|treatment)/).uniq,
      full_text: normalized
    }
  end

  def calculate_similarity(fp1, fp2)
    scores = []

    if !fp1[:dates].empty? && !fp2[:dates].empty?
      date_overlap = (fp1[:dates] & fp2[:dates]).size.to_f / [fp1[:dates].size, fp2[:dates].size].max
      scores << date_overlap * 3.0
    end

    if !fp1[:providers].empty? && !fp2[:providers].empty?
      provider_overlap = (fp1[:providers] & fp2[:providers]).size.to_f / [fp1[:providers].size, fp2[:providers].size].max
      scores << provider_overlap * 2.0
    end

    scores << text_overlap(fp1[:preview], fp2[:preview])

    if !fp1[:medical_terms].empty? && !fp2[:medical_terms].empty?
      terms_overlap = (fp1[:medical_terms] & fp2[:medical_terms]).size.to_f / [fp1[:medical_terms].size, fp2[:medical_terms].size].max
      scores << terms_overlap
    end

    scores << text_overlap(fp1[:full_text][0..500], fp2[:full_text][0..500]) * 2.0

    return 0.0 if scores.empty?

    scores.sum / scores.size
  end

  def text_overlap(text1, text2)
    return 0.0 if text1.nil? || text1.empty? || text2.nil? || text2.empty?

    words1 = text1.split
    words2 = text2.split

    return 0.0 if words1.empty? || words2.empty?

    intersection = (words1 & words2).size.to_f
    union = (words1 | words2).size.to_f

    union > 0 ? intersection / union : 0.0
  end

  def categorize_confidence(score)
    if score > 0.8
      "SAME DOCUMENT"
    elsif score > 0.5
      "LIKELY SAME"
    elsif score > 0.3
      "WEAK MATCH"
    else
      "DIFFERENT DOCUMENTS"
    end
  end
end
