# frozen_string_literal: true

# Scores Medical Summary outputs for quality and formatting compliance.
#
# Two modes:
#   - Document-first runs: scores letter content from the Letters API
#   - Old-pipeline runs: scores Medical Summary execution outputs
#
# Produces a structured JSON scorecard with per-letter pass/fail and aggregate stats.
class SummaryScorer
  RUBRICS = {
    'Reports by Psychologists, Psychiatrists, Neuropsychologists' => {
      header_shape: :standard_clinical,
      required_sections: %w[Subjective Assessment],
      content_type: :condensed
    },
    'Progress Notes and Reports by Treating Physicians' => {
      header_shape: :standard_clinical,
      required_sections: %w[Subjective Assessment],
      content_type: :condensed
    },
    'Diagnostic Studies (X-rays/MRI)' => {
      header_shape: :imaging,
      required_sections: %w[Findings Impression],
      content_type: :condensed
    },
    'Diagnostic Studies (NCS Studies)' => {
      header_shape: :ncs,
      required_sections: %w[Conclusion],
      content_type: :condensed
    },
    'Laboratory Report' => {
      header_shape: :lab_pathology,
      required_sections: [],
      content_type: :condensed
    },
    'Pathology Report' => {
      header_shape: :lab_pathology,
      required_sections: %w[Diagnosis],
      content_type: :condensed
    },
    'QME (Qualified Medical Evaluation), AME (Agreed Medical Examination), Panel QME Reports in Psychology, Panel QME Reports from Non-Psychiatric Specialists, Supplementals and QMEs from mental health professionals, Non-psych reports Supplementals AME QME' => {
      header_shape: :qme,
      required_sections: %w[Subjective Assessment Impairment],
      content_type: :condensed
    },
    'Request for Authorization' => {
      header_shape: :standard_clinical,
      required_sections: %w[Diagnosis],
      content_type: :condensed
    },
    'Operative Report' => {
      header_shape: :operative,
      required_sections: [],
      content_type: :condensed
    },
    'Letter' => {
      header_shape: :operative,
      required_sections: [],
      content_type: :verbatim
    },
    'Emergency Report' => {
      header_shape: :operative,
      required_sections: %w[Subjective Assessment],
      content_type: :condensed
    },
    'Cover Letters and Position Statements' => {
      header_shape: :cover_letter,
      required_sections: [],
      content_type: :condensed
    },
    'Depositions' => {
      header_shape: :deposition,
      required_sections: [],
      content_type: :verbatim
    },
    'Depositions, Condensed' => {
      header_shape: :deposition,
      required_sections: [],
      content_type: :condensed
    },
    'Performance and Disciplinary Records' => {
      header_shape: :hr_record,
      required_sections: [],
      content_type: :condensed
    },
    'Claims' => {
      header_shape: :claims,
      required_sections: [],
      content_type: :condensed
    },
    'Filings' => {
      header_shape: :claims,
      required_sections: [],
      content_type: :condensed
    }
  }.freeze

  DEFAULT_RUBRIC = {
    header_shape: :standard_clinical,
    required_sections: %w[Subjective Assessment],
    content_type: :condensed
  }.freeze

  SUBCATEGORY_ALIASES = {
    'QME' => 'QME (Qualified Medical Evaluation), AME (Agreed Medical Examination), Panel QME Reports in Psychology, Panel QME Reports from Non-Psychiatric Specialists, Supplementals and QMEs from mental health professionals, Non-psych reports Supplementals AME QME',
    'AME' => 'QME (Qualified Medical Evaluation), AME (Agreed Medical Examination), Panel QME Reports in Psychology, Panel QME Reports from Non-Psychiatric Specialists, Supplementals and QMEs from mental health professionals, Non-psych reports Supplementals AME QME',
    'Panel QME' => 'QME (Qualified Medical Evaluation), AME (Agreed Medical Examination), Panel QME Reports in Psychology, Panel QME Reports from Non-Psychiatric Specialists, Supplementals and QMEs from mental health professionals, Non-psych reports Supplementals AME QME',
    'Supplemental' => 'QME (Qualified Medical Evaluation), AME (Agreed Medical Examination), Panel QME Reports in Psychology, Panel QME Reports from Non-Psychiatric Specialists, Supplementals and QMEs from mental health professionals, Non-psych reports Supplementals AME QME',
    'Progress Notes' => 'Progress Notes and Reports by Treating Physicians',
    'Psych Reports' => 'Reports by Psychologists, Psychiatrists, Neuropsychologists',
    'Imaging' => 'Diagnostic Studies (X-rays/MRI)',
    'NCS' => 'Diagnostic Studies (NCS Studies)',
    'EMG' => 'Diagnostic Studies (NCS Studies)',
    'Lab' => 'Laboratory Report',
    'Pathology' => 'Pathology Report',
    'Cover Letter' => 'Cover Letters and Position Statements',
    'Deposition' => 'Depositions'
  }.freeze

  def self.rubric_for(subcategory)
    subcategories = Array(subcategory)
    subcategories.each { |sub| return RUBRICS[sub] if RUBRICS.key?(sub) }
    subcategories.each do |sub|
      SUBCATEGORY_ALIASES.each { |alias_key, full_key| return RUBRICS[full_key] if sub.include?(alias_key) }
    end
    DEFAULT_RUBRIC
  end

  def self.extract_header(content)
    return nil if content.nil? || content.strip.empty?
    content.each_line { |line| stripped = line.strip; return stripped unless stripped.empty? }
    nil
  end

  def self.parse_header_date(header)
    return nil if header.nil?
    match = header.match(/\[([A-Z][a-z]+ \d{1,2},? \d{4})/i)
    return match[1] if match
    return 'Unknown' if header.match?(/\[Unknown[,\s]/i)
    match = header.match(/^#?\s*([A-Z][a-z]+ \d{1,2},? \d{4})/i)
    match ? match[1] : nil
  end

  def self.parse_header_provider(header)
    return nil if header.nil?
    match = header.match(/- ([^-\]]+)\]\{\.underline\}/i)
    return match[1].strip if match
    match = header.match(/Cover Letter - (.+)$/i)
    return match[1].strip if match
    nil
  end

  # --- Scoring Checks ---
  # Each returns an array of issue hashes: { check:, severity:, message: }

  def self.check_header_format(content, header_shape)
    header = extract_header(content)
    return [] if header.nil?
    issues = []
    if header_shape == :cover_letter
      unless header.match?(/Cover Letter/i)
        issues << { check: 'header_format', severity: 'warning',
                    message: "Cover letter header missing 'Cover Letter' label: #{header[0..80]}" }
      end
    else
      if header.match?(/^#\s*\[.+\]\{\.underline\}/)
        # Full pattern matches — no issues
      elsif !header.start_with?('#')
        issues << { check: 'header_format', severity: 'warning',
                    message: "Header missing # heading prefix: #{header[0..80]}" }
      elsif !header.include?('{.underline}')
        issues << { check: 'header_format', severity: 'warning',
                    message: "Header missing {.underline} markup: #{header[0..80]}" }
      else
        issues << { check: 'header_format', severity: 'warning',
                    message: "Header missing bracket structure [...]{.underline}: #{header[0..80]}" }
      end
    end
    issues
  end

  def self.check_date_consistency(content, expected_date)
    return [] if expected_date.nil? || expected_date.strip.empty?
    header = extract_header(content)
    return [] if header.nil?
    header_date = parse_header_date(header)
    return [] if header_date.nil?
    normalize = ->(d) { d.to_s.gsub(',', '').strip.downcase }
    if normalize.call(header_date) != normalize.call(expected_date)
      [{ check: 'date_consistency', severity: 'error',
         message: "Header date '#{header_date}' does not match expected '#{expected_date}'" }]
    else
      []
    end
  end

  def self.check_provider_consistency(content, expected_provider)
    return [] if expected_provider.nil? || expected_provider.strip.empty?
    header = extract_header(content)
    return [] if header.nil?
    header_provider = parse_header_provider(header)
    return [] if header_provider.nil?
    normalize_name = lambda do |name|
      cleaned = name.gsub(/,?\s*(MD|DO|PhD|PsyD|LCSW|MFT|NP|PA|Esq\.?|Jr\.?|Sr\.?|III?|IV)\b/i, '')
      cleaned.strip.downcase
    end
    expected_norm = normalize_name.call(expected_provider)
    header_norm = normalize_name.call(header_provider)
    last_name_expected = expected_norm.split(/[\s,]+/).last
    last_name_header = header_norm.split(/[\s,]+/).last
    if header_norm == expected_norm || last_name_header == last_name_expected
      []
    else
      [{ check: 'provider_consistency', severity: 'warning',
         message: "Header provider '#{header_provider}' does not match expected '#{expected_provider}'" }]
    end
  end

  def self.check_empty_content(content, page_count)
    is_empty = content.nil? || content.strip.empty?
    if is_empty && page_count.to_i > 1
      [{ check: 'empty_content', severity: 'error',
         message: "Empty summary for #{page_count}-page letter" }]
    else
      []
    end
  end

  def self.check_required_sections(content, required_sections)
    return [] if required_sections.empty?
    return [] if content.nil? || content.strip.empty?
    body = content.lines.drop(1).join
    missing = required_sections.reject { |section| body.match?(/#{Regexp.escape(section)}/i) }
    if missing.any?
      [{ check: 'required_sections', severity: 'warning',
         message: "Missing expected sections: #{missing.join(', ')}" }]
    else
      []
    end
  end

  CHARS_PER_PAGE_THRESHOLD = 50

  def self.check_content_length(content, page_count)
    return [] if page_count.to_i <= 2
    return [] if content.nil? || content.strip.empty? # Empty handled by check_empty_content
    body = content.lines.drop(1).join.strip
    expected_min = page_count.to_i * CHARS_PER_PAGE_THRESHOLD
    if body.length < expected_min
      [{ check: 'content_length', severity: 'warning',
         message: "Summary body is #{body.length} chars for #{page_count} pages (expected >= #{expected_min})" }]
    else
      []
    end
  end
end
