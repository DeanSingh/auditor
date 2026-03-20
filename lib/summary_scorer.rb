# frozen_string_literal: true

require 'date'

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
    },
    'Encounter Records and Scheduling Documentation' => {
      header_shape: :standard_clinical,
      required_sections: [],
      content_type: :condensed
    },
    'Occupational Medicine Reports' => {
      header_shape: :standard_clinical,
      required_sections: [],
      content_type: :condensed
    },
    'Radiology Reports' => {
      header_shape: :imaging,
      required_sections: %w[Findings Impression],
      content_type: :condensed
    },
    'Legal Processing Forms' => {
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
    'RFA' => 'Request for Authorization',
    'Cover Letter' => 'Cover Letters and Position Statements',
    'Deposition' => 'Depositions',
    'Encounter Records' => 'Encounter Records and Scheduling Documentation',
    'Occupational Medicine' => 'Occupational Medicine Reports',
    'Radiology' => 'Radiology Reports',
    'DOT' => 'Occupational Medicine Reports'
  }.freeze

  ORG_INDICATORS = /\b(LLC|LLP|Inc|Corp|Corporation|Administration|Department|City of|County of|Permanente|Associates|Foundation|University|Hospital|Medical Center|Clinic|Health\s+(?:System|Plan|Group)|Group|Services|Federal)\b/i.freeze

  CREDENTIAL_PATTERN = /,?\s*\(?(?:MD|DO|DC|PhD|PsyD|LCSW|MFT|NP|PA|Esq\.?|Jr\.?|Sr\.?|III?|IV|D\.?C\.?|M\.?D\.?|D\.?O\.?)\)?\b/i.freeze

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

    # Extract content between brackets: [Date, Report - Provider - Facility]{.underline}
    bracket_match = header.match(/\[(.+)\]\{\.underline\}/i)
    if bracket_match
      # Split on " - " to get segments: ["Date, Report", "Provider", "Facility"]
      segments = bracket_match[1].split(' - ')
      # Provider is the second segment (index 1) for multi-dash headers,
      # or the last segment for single-dash headers like [Date, Report - Provider]
      return segments[1].strip if segments.length >= 2
    end

    # Cover letter: Cover Letter - Attorney to Recipient
    match = header.match(/Cover Letter - (.+)$/i)
    return match[1].strip if match

    nil
  end

  # --- Scoring Checks ---
  # Each returns an array of issue hashes: { check:, severity:, message: }

  def self.check_header_format(content, header_shape, header: nil)
    header ||= extract_header(content)
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

  def self.check_date_consistency(content, expected_date, header: nil)
    return [] if expected_date.nil? || expected_date.strip.empty?
    return [] if expected_date.strip.downcase == 'unknown'
    header ||= extract_header(content)
    return [] if header.nil?
    header_date = parse_header_date(header)
    return [] if header_date.nil?
    return [] if header_date == 'Unknown'

    # Try Date.parse to handle ISO (2016-08-29) vs human-readable (August 29, 2016)
    begin
      parsed_expected = Date.parse(expected_date)
      parsed_header = Date.parse(header_date)
      return [] if parsed_expected == parsed_header
    rescue Date::Error
      # Fall through to string comparison if parsing fails
    end

    # String normalization fallback for partial or unusual date formats
    normalize = ->(d) { d.to_s.gsub(',', '').strip.downcase }
    return [] if normalize.call(header_date) == normalize.call(expected_date)

    [{ check: 'date_consistency', severity: 'error',
       message: "Header date '#{header_date}' does not match expected '#{expected_date}'" }]
  end

  def self.check_provider_consistency(content, expected_provider, header: nil)
    return [] if expected_provider.nil? || expected_provider.strip.empty?
    header ||= extract_header(content)
    return [] if header.nil?
    header_provider = parse_header_provider(header)
    return [] if header_provider.nil?

    # Skip org-vs-person comparisons: Extract Info often captures the institution,
    # but Medical Summary correctly writes the individual physician in the header.
    return [] if likely_org?(expected_provider) && header_provider.match?(CREDENTIAL_PATTERN)

    # Strip "to <Recipient>" suffix from cover letter providers before comparing
    cleaned_expected = expected_provider.sub(/\s+to\s+.+$/i, '')

    normalize_name = lambda do |name|
      # Strip credentials: MD, DO, PhD, (M.D.), etc.
      cleaned = name.gsub(CREDENTIAL_PATTERN, '')
      # Normalize "LAST, FIRST MIDDLE" → "first middle last"
      parts = cleaned.strip.split(/,\s*/, 2)
      normalized = parts.length == 2 ? "#{parts[1]} #{parts[0]}" : parts[0]
      normalized.strip.downcase.squeeze(' ')
    end

    expected_norm = normalize_name.call(cleaned_expected)
    header_norm = normalize_name.call(header_provider)

    last_name_expected = expected_norm.split(/\s+/).last
    last_name_header = header_norm.split(/\s+/).last

    if header_norm == expected_norm || last_name_header == last_name_expected
      []
    else
      [{ check: 'provider_consistency', severity: 'warning',
         message: "Header provider '#{header_provider}' does not match expected '#{expected_provider}'" }]
    end
  end

  def self.likely_org?(name)
    return false if name.nil?
    name.match?(ORG_INDICATORS)
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

  def self.check_required_sections(content, required_sections, body: nil)
    return [] if required_sections.empty?
    return [] if content.nil? || content.strip.empty?
    body ||= content.lines.drop(1).join
    missing = required_sections.reject do |section|
      equivalents = SECTION_EQUIVALENTS.fetch(section, [section])
      equivalents.any? { |term| body.match?(/#{Regexp.escape(term)}/i) }
    end
    if missing.any?
      [{ check: 'required_sections', severity: 'warning',
         message: "Missing expected sections: #{missing.join(', ')}" }]
    else
      []
    end
  end

  CHECK_NAMES = %w[header_format date_consistency provider_consistency empty_content required_sections content_length].freeze

  SECTION_EQUIVALENTS = {
    'Assessment' => %w[Assessment Impression Diagnosis Diagnoses],
    'Subjective' => %w[Subjective Chief\ Complaint HPI History\ of\ Present\ Illness],
    'Findings' => %w[Findings Results],
    'Conclusion' => %w[Conclusion Summary Interpretation],
    'Impairment' => %w[Impairment Disability WPI],
  }.freeze

  CHARS_PER_PAGE_THRESHOLD = 20

  def self.check_content_length(content, page_count, body: nil)
    return [] if page_count.to_i <= 2
    return [] if content.nil? || content.strip.empty? # Empty handled by check_empty_content
    body = (body || content.lines.drop(1).join).strip
    expected_min = page_count.to_i * CHARS_PER_PAGE_THRESHOLD
    if body.length < expected_min
      [{ check: 'content_length', severity: 'warning',
         message: "Summary body is #{body.length} chars for #{page_count} pages (expected >= #{expected_min})" }]
    else
      []
    end
  end

  def initialize(client:)
    @client = client
  end

  def score(run_id)
    summary = @client.fetch_run_summary(run_id)
    raise "Run #{run_id} not found" if summary.nil?

    unless summary['status'] == 'SUCCEEDED'
      warn "Warning: Run #{run_id} status is #{summary['status']} — results may be incomplete"
    end

    letters = if document_first?(summary)
      fetch_document_first_letters(run_id)
    else
      fetch_old_pipeline_letters(run_id)
    end

    scored = letters.map { |letter| score_letter(letter) }

    build_scorecard(run_id, scored)
  end

  private

  def document_first?(data)
    data['documentable'] == true || data['document'].is_a?(Hash)
  end

  def fetch_document_first_letters(run_id)
    @client.fetch_run_document_letters_with_content(run_id) || []
  end

  def fetch_old_pipeline_letters(run_id)
    data = @client.fetch_run_executions(run_id, step_name: 'Medical Summary')
    executions = (data&.dig('executions') || []).select { |e| e['status'] == 'SUCCEEDED' }

    executions.map do |e|
      prompt = e['prompt'] || ''
      output = e['output'] || ''

      content_match = output.match(%r{<content>(.*?)</content>}m)
      content = content_match ? content_match[1].strip : output

      date = prompt.match(/^Date:\s*([^\n]+)/)&.[](1)&.strip
      provider = prompt.match(/^Provider:\s*([^\n]+)/)&.[](1)&.strip
      subcategories = prompt.scan(/Sub-category:\s*(.+)/).flatten.map(&:strip).uniq
      page_count_match = prompt.match(/Pages in document:\s*(\d+)/m)
      page_count = page_count_match ? page_count_match[1].to_i : 1

      {
        'index' => e['iteration'],
        'date' => date,
        'provider' => provider,
        'subcategory' => subcategories,
        'category' => [],
        'pageCount' => page_count,
        'content' => content
      }
    end
  end

  def score_letter(letter)
    content = letter['content'] || ''
    subcategory = letter['subcategory']
    rubric = self.class.rubric_for(subcategory)

    # Pre-compute header and body once to avoid redundant parsing across checks
    header = self.class.extract_header(content)
    body = content.lines.drop(1).join unless content.strip.empty?

    issues = []
    issues.concat(self.class.check_header_format(content, rubric[:header_shape], header: header))
    issues.concat(self.class.check_date_consistency(content, letter['date'], header: header))
    issues.concat(self.class.check_provider_consistency(content, letter['provider'], header: header))
    issues.concat(self.class.check_empty_content(content, letter['pageCount']))
    issues.concat(self.class.check_required_sections(content, rubric[:required_sections], body: body))
    issues.concat(self.class.check_content_length(content, letter['pageCount'], body: body))

    {
      'index' => letter['index'],
      'date' => letter['date'],
      'provider' => letter['provider'],
      'subcategory' => Array(subcategory).first || 'Unknown',
      'page_count' => letter['pageCount'],
      'issues' => issues.map { |i| { 'check' => i[:check], 'severity' => i[:severity], 'message' => i[:message] } },
      'passed' => issues.none? { |i| i[:severity] == 'error' },
      'warnings' => issues.count { |i| i[:severity] == 'warning' },
      'errors' => issues.count { |i| i[:severity] == 'error' }
    }
  end

  def build_scorecard(run_id, scored_letters)
    checks = Hash.new { |h, k| h[k] = { 'passed' => 0, 'failed' => 0 } }

    scored_letters.each do |letter|
      failed_checks = letter['issues'].map { |i| i['check'] }.uniq

      CHECK_NAMES.each do |check|
        if failed_checks.include?(check)
          checks[check]['failed'] += 1
        else
          checks[check]['passed'] += 1
        end
      end
    end

    flagged = scored_letters.reject { |l| l['passed'] && l['warnings'].zero? }

    {
      'run_id' => run_id,
      'letters_scored' => scored_letters.length,
      'summary' => {
        'passed' => scored_letters.count { |l| l['passed'] && l['warnings'].zero? },
        'flagged' => flagged.length,
        'errors' => scored_letters.sum { |l| l['errors'] },
        'warnings' => scored_letters.sum { |l| l['warnings'] },
        'checks' => checks
      },
      'flagged_letters' => flagged,
      'letters' => scored_letters
    }
  end
end
