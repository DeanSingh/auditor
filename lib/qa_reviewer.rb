# frozen_string_literal: true

require 'date'
require 'set'
require 'json'

# QA reviewer for Record Review runs.
#
# Performs multi-dimensional checks against Extract Info source data:
#   - DOS verification: compares letter dates against per-page Extract Info dates
#   - Content coverage: checks that letter content reflects source material (stub)
#   - Redundancy detection: flags duplicate content across letters (stub)
#   - Provider availability: checks provider claims match source (stub)
#
# Two modes:
#   - Document-first runs: reads letters via document association
#   - Old-pipeline runs: reconstructs letters from Medical Summary prompts
class QAReviewer
  DOS_WITH_DATE = /(?:date of service|(?<!\w)dos(?!\w)|encounter date|service date|exam date|visit date|appointment date|date of exam|date of visit|date of evaluation|evaluation date)[:\s]{0,10}(\d{1,2}\/\d{1,2}\/\d{2,4}|\d{4}-\d{2}-\d{2}|[A-Z][a-z]+\.?\s+\d{1,2},?\s+\d{4})/i.freeze

  METADATA_FIELDS = Set.new(%w[
    date provider category subcategory doc_category pageNumber pageCount index id
  ]).freeze

  REDUNDANCY_THRESHOLD = 0.85

  # --- Class-level checks ---
  # Each returns an array of issue hashes: { check:, severity:, message: }

  # Checks that the letter's date of service is consistent with Extract Info source data.
  #
  # Three subchecks:
  #   1. Extract Info found a different date than the letter → error
  #   2. Letter says Unknown but source text contains a DOS-labeled date → warning
  #   3. Source contains DOS-labeled dates that don't match the letter date → error
  def self.check_dos(letter, extracts)
    return [] if extracts.empty?

    letter_date = letter['date'].to_s.strip
    pages = letter['pages'] || []
    page_numbers = pages.map { |p| p['pageNumber'].to_i }

    # Map page numbers to extracts by iteration (pageNumber - 1 = iteration index)
    relevant_extracts = extracts.select do |e|
      page_numbers.include?(e['iteration'].to_i + 1)
    end

    return [] if relevant_extracts.empty?

    issues = []
    unknown_letter = letter_date.downcase == 'unknown' || letter_date.empty?

    relevant_extracts.each do |extract|
      result = parse_result(extract['result'])
      extract_date = result&.dig('date').to_s.strip

      next if extract_date.empty? || extract_date.downcase == 'unknown'

      if unknown_letter
        # Subcheck 2: letter is Unknown but Extract Info found a real date
        issues << {
          check: 'dos_verification',
          severity: 'error',
          message: "Letter has unknown date but Extract Info found '#{extract_date}' on page #{extract['iteration'].to_i + 1}"
        }
      elsif !dates_match?(letter_date, extract_date)
        # Subcheck 1: Extract Info date differs from letter date
        issues << {
          check: 'dos_verification',
          severity: 'error',
          message: "Extract Info date '#{extract_date}' differs from letter date '#{letter_date}' on page #{extract['iteration'].to_i + 1}"
        }
      end
    end

    # Subcheck 2 (warning path): letter is Unknown but source text has DOS-labeled dates
    if unknown_letter && issues.empty?
      relevant_extracts.each do |extract|
        source_text = extract_processed_content(extract['prompt'].to_s)
        dos_match = find_dos_in_text(source_text)
        next unless dos_match

        issues << {
          check: 'dos_verification',
          severity: 'error',
          message: "Letter has unknown date but source text contains '#{dos_match}' on page #{extract['iteration'].to_i + 1}"
        }
        break # One warning per letter is sufficient
      end
    end

    # Subcheck 3: source text has DOS-labeled dates that don't match letter date
    unless unknown_letter
      relevant_extracts.each do |extract|
        source_text = extract_processed_content(extract['prompt'].to_s)
        dos_match = find_dos_in_text(source_text)
        next unless dos_match
        next if dates_match?(letter_date, dos_match)

        issues << {
          check: 'dos_verification',
          severity: 'error',
          message: "Source text has DOS '#{dos_match}' that differs from letter date '#{letter_date}' on page #{extract['iteration'].to_i + 1}"
        }
      end
    end

    issues.uniq
  end

  # Checks that letter content covers the key information from source pages.
  #
  # Known limitation: uses substring phrase matching, not semantic comparison.
  # Extract Info often contains templated phrasing ("The patient was seen for
  # follow-up") that gets condensed differently in summaries. Expect false
  # positives — calibrate against real runs before treating as ground truth.
  def self.check_content_coverage(letter, page_extracts)
    content = letter['content'] || ''
    return [] if content.strip.empty?
    return [] if page_extracts.empty?

    issues = []

    body = content.lines.drop(1).join.downcase

    page_extracts.each do |extract|
      result = parse_result(extract['result'])
      next unless result

      page_num = (extract['iteration'] || 0) + 1
      missing_fields = []

      result.each do |field, value|
        next if METADATA_FIELDS.include?(field)
        next unless value.is_a?(String) && value.strip.length > 20

        phrases = extract_significant_phrases(value)
        next if phrases.empty?

        found = phrases.any? { |phrase| body.include?(phrase.downcase) }
        missing_fields << field unless found
      end

      unless missing_fields.empty?
        issues << { check: 'content_coverage', severity: 'warning',
                    message: "Content from page #{page_num} not reflected in summary: #{missing_fields.join(', ')}" }
      end
    end

    issues
  end

  def self.extract_significant_phrases(text)
    return [] if text.nil? || text.strip.empty?

    phrases = text.split(/[.;:\n]+/).map(&:strip).reject(&:empty?)
    phrases.select { |p| p.split(/\s+/).length >= 3 }
  end

  # Checks for redundant/duplicate content between letters.
  def self.check_redundancy(letters)
    findings = {}
    return findings if letters.length < 2

    letters.each_with_index do |letter_a, i|
      ((i + 1)...letters.length).each do |j|
        letter_b = letters[j]

        pages_a = Set.new((letter_a['pages'] || []).map { |p| p['pageNumber'] })
        pages_b = Set.new((letter_b['pages'] || []).map { |p| p['pageNumber'] })
        overlapping = !(pages_a & pages_b).empty?

        content_a = letter_a['content'] || ''
        content_b = letter_b['content'] || ''
        similar = content_a.length > 50 && content_b.length > 50 &&
                  cosine_similarity(content_a, content_b) > REDUNDANCY_THRESHOLD

        next unless overlapping || similar

        index_a = letter_a['index'] || i
        index_b = letter_b['index'] || j
        pages_b_str = format_page_range(pages_b.to_a.sort)
        pages_a_str = format_page_range(pages_a.to_a.sort)
        provider_b = letter_b['provider'] || 'Unknown'
        provider_a = letter_a['provider'] || 'Unknown'

        findings[index_a] ||= []
        findings[index_a] << { check: 'redundancy', severity: 'warning',
                               message: "Similar to letter at pages #{pages_b_str} (#{provider_b})" }
        findings[index_b] ||= []
        findings[index_b] << { check: 'redundancy', severity: 'warning',
                               message: "Similar to letter at pages #{pages_a_str} (#{provider_a})" }
      end
    end

    findings
  end

  def self.cosine_similarity(text_a, text_b)
    words_a = text_a.downcase.scan(/\w+/).tally
    words_b = text_b.downcase.scan(/\w+/).tally

    all_words = words_a.keys | words_b.keys
    return 0.0 if all_words.empty?

    dot = all_words.sum { |w| (words_a[w] || 0) * (words_b[w] || 0) }
    mag_a = Math.sqrt(words_a.values.sum { |v| v * v })
    mag_b = Math.sqrt(words_b.values.sum { |v| v * v })

    return 0.0 if mag_a.zero? || mag_b.zero?

    dot.to_f / (mag_a * mag_b)
  end

  # Checks provider availability claims against source data.
  def self.check_provider_availability(letter, page_extracts)
    return [] if provider_present?(letter['provider'])

    source_has_provider = page_extracts.any? do |extract|
      result = parse_result(extract['result'])
      next false unless result

      provider_present?(result['provider'])
    end

    return [] if source_has_provider

    [{ check: 'provider_availability', severity: 'info',
       message: 'No provider name available for review' }]
  end

  def self.provider_present?(value)
    return false if value.nil?

    stripped = value.strip
    !stripped.empty? && stripped.downcase != 'unknown'
  end

  # --- Helper methods ---

  def self.dates_match?(date_a, date_b)
    Date.parse(date_a) == Date.parse(date_b)
  rescue Date::Error
    normalize = ->(d) { d.to_s.gsub(',', '').strip.downcase }
    normalize.call(date_a) == normalize.call(date_b)
  end

  # Extracts text inside <processed_content>...</processed_content> tags.
  # Returns the full string if no tags found.
  def self.extract_processed_content(text)
    match = text.match(%r{<processed_content>(.*?)</processed_content>}m)
    match ? match[1] : text
  end

  # Returns the first DOS-labeled date found in text, or nil.
  def self.find_dos_in_text(text)
    match = text.match(DOS_WITH_DATE)
    match ? match[1].strip : nil
  end

  # Parses JSON result string, returning nil on failure.
  def self.parse_result(result_str)
    return nil if result_str.nil? || result_str.strip.empty?
    JSON.parse(result_str)
  rescue JSON::ParserError
    nil
  end

  # Formats a sorted array of page numbers as a compact range string.
  # e.g. [1,2,3,5,6] → "1-3, 5-6"
  def self.format_page_range(page_numbers)
    sorted = page_numbers.map(&:to_i).sort.uniq
    return '' if sorted.empty?

    ranges = []
    start = sorted.first
    last = sorted.first

    sorted[1..].each do |n|
      if n == last + 1
        last = n
      else
        ranges << (start == last ? start.to_s : "#{start}-#{last}")
        start = n
        last = n
      end
    end
    ranges << (start == last ? start.to_s : "#{start}-#{last}")
    ranges.join(', ')
  end

  # --- Instance methods ---

  def initialize(client:)
    @client = client
  end

  # Reviews a run and returns a structured findings report.
  def review(run_id)
    summary = @client.fetch_run_summary(run_id)
    raise "Run #{run_id} not found" if summary.nil?

    unless summary['status'] == 'SUCCEEDED'
      warn "Warning: Run #{run_id} status is #{summary['status']} — results may be incomplete"
    end

    letters = fetch_letters(run_id, summary)
    extract_step = find_extract_info_step_name(summary)
    extracts = fetch_extract_info(run_id, extract_step)

    findings = []
    timing = {}

    letters.each do |letter|
      letter_pages = letter_page_numbers(letter)
      letter_extracts = extracts.select { |e| letter_pages.include?(e['iteration'].to_i + 1) }

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      dos_issues = self.class.check_dos(letter, letter_extracts)
      coverage_issues = self.class.check_content_coverage(letter, letter_extracts)
      provider_issues = self.class.check_provider_availability(letter, letter_extracts)

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      timing[letter['index'] || letter['iteration']] = elapsed.round(4)

      all_issues = dos_issues + coverage_issues + provider_issues
      next if all_issues.empty?

      findings << build_finding(letter, all_issues)
    end

    redundancy_result = self.class.check_redundancy(letters)
    findings = merge_redundancy_findings(findings, redundancy_result)

    build_report(run_id, letters.length, findings, timing)
  end

  private

  def fetch_letters(run_id, summary)
    if document_first?(summary)
      @client.fetch_run_document_letters_with_content(run_id) || []
    else
      fetch_old_pipeline_letters(run_id)
    end
  end

  def document_first?(data)
    data['documentable'] == true || data['document'].is_a?(Hash)
  end

  def fetch_old_pipeline_letters(run_id)
    step_name = 'Medical Summary'
    data = @client.fetch_run_executions(run_id, step_name: step_name)
    executions = (data&.dig('executions') || []).select { |e| e['status'] == 'SUCCEEDED' }

    executions.map do |e|
      prompt = e['prompt'] || ''

      # Parse page numbers from "- Page: N" lines in the prompt
      page_numbers = prompt.scan(/^-\s*Page:\s*(\d+)/i).flatten.map(&:to_i)
      pages = page_numbers.map { |n| { 'pageNumber' => n } }

      date = prompt.match(/^Date:\s*([^\n]+)/)&.[](1)&.strip
      provider = prompt.match(/^Provider:\s*([^\n]+)/)&.[](1)&.strip
      subcategories = prompt.scan(/Sub-category:\s*(.+)/).flatten.map(&:strip).uniq

      {
        'index' => e['iteration'],
        'iteration' => e['iteration'],
        'date' => date,
        'provider' => provider,
        'subcategory' => subcategories,
        'pages' => pages,
        'content' => e['output'] || ''
      }
    end
  end

  def find_extract_info_step_name(summary)
    steps = summary.dig('workflow', 'steps') || []
    match = steps.find { |s| s['name']&.match?(/extract info/i) }
    match&.dig('name') || 'Extract Info'
  end

  def fetch_extract_info(run_id, step_name)
    data = @client.fetch_run_executions(run_id, step_name: step_name)
    (data&.dig('executions') || []).select { |e| e['status'] == 'SUCCEEDED' }
  end

  def letter_page_numbers(letter)
    (letter['pages'] || []).map { |p| p['pageNumber'].to_i }
  end

  # Converts internal symbol-keyed issue hashes to string-keyed output format.
  def serialize_issues(issues)
    issues.map { |i| { 'check' => i[:check], 'severity' => i[:severity], 'message' => i[:message] } }
  end

  def build_finding(letter, issues)
    page_nums = letter_page_numbers(letter)
    {
      'index' => letter['index'],
      'date' => letter['date'],
      'provider' => letter['provider'],
      'category' => Array(letter['subcategory']).first || letter.dig('category', 0) || '',
      'pages' => self.class.format_page_range(page_nums),
      'page_count' => page_nums.length,
      'issues' => serialize_issues(issues),
      'errors' => issues.count { |i| i[:severity] == 'error' },
      'warnings' => issues.count { |i| i[:severity] == 'warning' }
    }
  end

  def merge_redundancy_findings(findings, redundancy_result)
    return findings if redundancy_result.nil? || redundancy_result.empty?

    redundancy_result.each do |index, redundancy_issues|
      existing = findings.find { |f| f['index'] == index }
      if existing
        redundancy_issues.each do |issue|
          existing['issues'] << serialize_issues([issue]).first
          existing['errors'] += 1 if issue[:severity] == 'error'
          existing['warnings'] += 1 if issue[:severity] == 'warning'
        end
      else
        findings << {
          'index' => index,
          'issues' => serialize_issues(redundancy_issues),
          'errors' => redundancy_issues.count { |i| i[:severity] == 'error' },
          'warnings' => redundancy_issues.count { |i| i[:severity] == 'warning' }
        }
      end
    end

    findings
  end

  def build_report(run_id, letter_count, findings, timing)
    {
      'run_id' => run_id,
      'letters_reviewed' => letter_count,
      'findings_count' => findings.length,
      'summary' => {
        'clean' => letter_count - findings.length,
        'flagged' => findings.length,
        'errors' => findings.sum { |f| f['errors'] },
        'warnings' => findings.sum { |f| f['warnings'] },
        'checks' => count_by_check(findings)
      },
      'flagged_findings' => findings,
      'findings' => findings,
      'timing_seconds' => timing
    }
  end

  def count_by_check(findings)
    counts = Hash.new { |h, k| h[k] = { 'count' => 0, 'errors' => 0, 'warnings' => 0 } }
    findings.each do |finding|
      finding['issues'].each do |issue|
        check = issue['check']
        counts[check]['count'] += 1
        counts[check]['errors'] += 1 if issue['severity'] == 'error'
        counts[check]['warnings'] += 1 if issue['severity'] == 'warning'
      end
    end
    counts
  end
end
