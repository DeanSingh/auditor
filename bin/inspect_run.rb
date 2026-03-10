#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative '../lib/cli_helpers'

# Inspects a workflow run via the GraphQL API.
#
# Two modes:
#   Summary:    bin/inspect_run.rb <run_id>
#   Drill-down: bin/inspect_run.rb <run_id> --step "Extract Info" --iteration 123
#
# Outputs JSON to stdout for consumption by the auditor agent.
#
# HIPAA notes:
#   - Execution outputs may contain PHI — this tool outputs to stdout only (no files written)
#   - Error messages are truncated to avoid leaking PHI
class RunInspector
  def initialize(run_id, step_name: nil, iteration: nil, iteration_min: nil, iteration_max: nil,
                 output_path: nil, stats: false, compact: false, fields: nil, where_filters: nil,
                 base_url: nil, org_name: nil)
    @run_id = run_id
    @step_name = step_name
    @iteration = iteration
    @iteration_min = iteration_min
    @iteration_max = iteration_max
    @output_path = output_path
    @stats = stats
    @compact = compact
    @fields = fields
    @where_filters = where_filters || []

    config = AuditorConfig.new
    base = base_url || config.base_url

    org_id = CLIHelpers.resolve_org_id(base_url: base, token: config.token!, name: org_name) if org_name

    @client = WorkflowClient.new(
      base_url: base,
      token: config.token!,
      org_id: org_id
    )
  end

  def run
    resolve_step_name! if @step_name

    if @stats && @step_name
      stats
    elsif @step_name
      drill_down
    else
      summary
    end
  end

  private

  # Fetch run data or exit with a "not found" error.
  # Centralizes the nil-check that every mode needs.
  def fetch_run!(method, **kwargs)
    data = @client.public_send(method, @run_id, **kwargs)

    if data.nil?
      warn "Error: Run #{@run_id} not found"
      exit 1
    end

    data
  end

  # Resolve step name case-insensitively. Exits with suggestions on mismatch.
  # Costs one lightweight API call (run summary) but eliminates silent empty results.
  def resolve_step_name!
    data = fetch_run!(:fetch_run_summary)
    steps = (data.dig('workflow', 'steps') || []).map { |s| s['name'] }

    # Exact match — no change needed
    return if steps.include?(@step_name)

    # Case-insensitive match
    match = steps.find { |s| s.downcase == @step_name.downcase }
    if match
      warn "Note: Matched step \"#{match}\" (from \"#{@step_name}\")"
      @step_name = match
      return
    end

    # No match — suggest alternatives
    warn "Error: Step \"#{@step_name}\" not found in this run"
    warn "Available steps:"
    steps.each { |s| warn "  - #{s}" }
    exit 1
  end

  def summary
    data = fetch_run!(:fetch_run_summary)

    # Group executions by step name for per-step counts
    exec_by_step = Hash.new { |h, k| h[k] = { succeeded: 0, failed: 0, other: 0 } }
    (data['executions'] || []).each do |e|
      step_name = e.dig('step', 'name') || 'unknown'
      case e['status']&.downcase
      when 'succeeded' then exec_by_step[step_name][:succeeded] += 1
      when 'failed' then exec_by_step[step_name][:failed] += 1
      else exec_by_step[step_name][:other] += 1
      end
    end

    # Build step list with execution counts and prompt templates
    steps = (data.dig('workflow', 'steps') || []).sort_by { |s| s['priority'] || 0 }.map do |step|
      counts = exec_by_step[step['name']]
      entry = {
        'name' => step['name'],
        'kind' => step['kind'],
        'execution_count' => counts[:succeeded] + counts[:failed] + counts[:other],
        'succeeded' => counts[:succeeded],
        'failed' => counts[:failed]
      }

      # Include prompt template for Prompt-type steps
      messages = step.dig('action', 'messages')
      if messages && !messages.empty?
        entry['prompt_template'] = messages.map { |m| "#{m['role']}: #{m['template']}" }.join("\n\n")
      end

      entry
    end

    emit({
      'run' => {
        'id' => data['id'],
        'status' => data['status'],
        'started' => data['started'],
        'finished' => data['finished']
      },
      'workflow' => {
        'name' => data.dig('workflow', 'name'),
        'steps' => steps
      },
      'stats' => data['stats']
    })
  end

  def drill_down
    data = fetch_run!(:fetch_run_executions,
      step_name: @step_name,
      iteration: @iteration,
      iteration_min: @iteration_min,
      iteration_max: @iteration_max
    )

    raw_executions = apply_where_filters(data['executions'] || [])

    if @compact
      # --summary: compact output with key fields per iteration
      rows = raw_executions.map { |e| compact_row(e) }
      emit({ 'step' => @step_name, 'total' => rows.size, 'iterations' => rows })
    else
      # Full output, optionally filtered by --fields
      executions = raw_executions.map do |e|
        entry = {
          'iteration' => e['iteration'],
          'status' => e['status'],
          'output' => e['output'],
          'result' => e['result'],
          'prompt' => e['prompt'],
          'started' => e['started'],
          'finished' => e['finished']
        }

        if @fields
          result = parse_result(e)
          entry['result'] = result.slice(*@fields) if result
          entry.delete('prompt')
          entry.delete('output')
        end

        entry
      end

      emit({ 'step' => @step_name, 'executions' => executions })
    end
  end

  # Aggregate result fields across all executions for a step.
  # Replaces the ad-hoc analysis scripts the audit agent writes every session.
  def stats
    data = fetch_run!(:fetch_run_executions, step_name: @step_name)

    executions = apply_where_filters(data['executions'] || []).select { |e| e['status'] == 'SUCCEEDED' }
    results = executions.filter_map { |e| parse_result(e) }

    if results.empty?
      warn "No succeeded executions with parseable results for step \"#{@step_name}\""
      exit 1
    end

    # Page-level stats
    dated = results.select { |r| r['date'] && r['date'] != 'Unknown' && r['date'] =~ /\d{4}/ }
    unknown = results.select { |r| r['date'].nil? || r['date'] == 'Unknown' }

    # Entry-level stats (entries = non-continuation pages, i.e. start of a new document group)
    entries = results.reject { |r| r['continuation'] }
    entries_dated = entries.select { |r| r['date'] && r['date'] != 'Unknown' && r['date'] =~ /\d{4}/ }
    entries_unknown = entries.select { |r| r['date'].nil? || r['date'] == 'Unknown' }

    # Unknown breakdown by subcategory
    unknown_by_subcat = tally(unknown, 'doc_subcategory')

    # Unknown breakdown by provider
    unknown_by_provider = tally(unknown, 'provider')

    # Date label distribution on unknowns
    unknown_by_label = tally(unknown, 'date_label')

    # Category distribution (all pages)
    by_category = tally(results, 'doc_category')

    emit({
      'step' => @step_name,
      'total_pages' => results.size,
      'pages' => {
        'dated' => dated.size,
        'unknown' => unknown.size,
        'unknown_pct' => pct(unknown.size, results.size)
      },
      'entries' => {
        'total' => entries.size,
        'dated' => entries_dated.size,
        'unknown' => entries_unknown.size,
        'unknown_pct' => pct(entries_unknown.size, entries.size)
      },
      'category_distribution' => by_category,
      'unknown_by_subcategory' => unknown_by_subcat,
      'unknown_by_provider' => unknown_by_provider,
      'unknown_by_date_label' => unknown_by_label
    })
  end

  # Parse the result field — it may be a JSON string or already a hash.
  def parse_result(execution)
    result = execution['result']
    return result if result.is_a?(Hash)
    return nil if result.nil?

    JSON.parse(result)
  rescue JSON::ParserError
    nil
  end

  # Count occurrences of a field value, sorted descending.
  def tally(items, field)
    counts = Hash.new(0)
    items.each { |r| counts[r[field] || 'N/A'] += 1 }
    counts.sort_by { |_, v| -v }.to_h
  end

  def pct(n, total)
    return 0.0 if total.zero?

    (n.to_f / total * 100).round(1)
  end

  # Filter executions by --where conditions applied to result fields.
  def apply_where_filters(executions)
    return executions if @where_filters.empty?

    executions.select do |e|
      result = parse_result(e)
      next false if result.nil?

      @where_filters.all? do |filter|
        field, value = filter.split('=', 2)
        result[field].to_s == value
      end
    end
  end

  # Compact representation of an execution: key fields only, plus filename from prompt.
  def compact_row(execution)
    result = parse_result(execution) || {}
    {
      'iteration' => execution['iteration'],
      'filename' => extract_filename(execution['prompt']),
      'date' => result['date'],
      'date_label' => result['date_label'],
      'continuation' => result['continuation'],
      'category' => result['doc_category'],
      'subcategory' => result['doc_subcategory'],
      'provider' => result['provider']
    }
  end

  # Extract source filename from the prompt text (interpolated from {{_.filename}}).
  def extract_filename(prompt)
    return nil if prompt.nil?

    match = prompt.match(%r{<filename>\s*(.+?)\s*</filename>}m)
    match ? match[1].strip : nil
  end

  # Write JSON to --output file (with summary on stderr) or stdout.
  def emit(data)
    json = JSON.pretty_generate(data)

    if @output_path
      File.write(@output_path, json)
      warn "Wrote #{json.bytesize} bytes to #{@output_path}"
    else
      puts json
    end
  end
end

# Main execution
if __FILE__ == $0
  step_name = nil
  iteration = nil
  iterations_raw = nil
  output_path = nil
  stats = false
  compact = false
  fields = nil
  where_filters = []
  base_url = nil
  org_name = nil

  parser = OptionParser.new do |opts|
    opts.banner = "Inspect a workflow run via the GraphQL API\n\n"
    opts.banner += "Usage: #{$0} <run_id> [options]\n"
    opts.banner += "       #{$0} <run_url> [options]"

    opts.separator ''
    opts.separator 'Options:'

    opts.on('--step NAME', 'Step name to drill into (e.g., "Extract Info")') do |name|
      step_name = name
    end

    opts.on('--iteration N', Integer, 'Single iteration to fetch (0-indexed)') do |n|
      iteration = n
    end

    opts.on('--iterations RANGE', 'Iteration range to fetch (e.g., "99-123")') do |range|
      iterations_raw = range
    end

    opts.on('-o', '--output FILE', 'Write JSON to file instead of stdout') do |path|
      output_path = path
    end

    opts.on('--stats', 'Analyze result fields and output aggregate stats (requires --step)') do
      stats = true
    end

    opts.on('--summary', 'Compact output with key fields per iteration (requires --step)') do
      compact = true
    end

    opts.on('--fields LIST', 'Comma-separated result fields to include (e.g., "date,thoughts")') do |list|
      fields = list.split(',').map(&:strip)
    end

    opts.on('--where EXPR', 'Filter by result field (e.g., "date=Unknown"). Repeatable.') do |expr|
      where_filters << expr
    end

    opts.on('--org NAME', 'Organization name') do |name|
      org_name = name
    end

    opts.on('--base-url URL', 'Override Workflow Labs base URL') do |url|
      base_url = url
    end

    opts.on('-h', '--help', 'Show this help message') do
      puts opts
      puts
      puts 'Modes:'
      puts '  Summary (no --step):     Shows workflow structure and per-step execution counts'
      puts '  Drill-down (with --step): Shows full execution data for a step + iteration'
      puts
      puts 'Examples:'
      puts "  #{$0} 8564                                     # Summary"
      puts "  #{$0} https://workflow.ing/dashboard/runs/8564  # Summary (URL)"
      puts "  #{$0} 8564 --step \"Extract Info\" --iteration 123"
      puts "  #{$0} 8564 --step \"Extract Info\" --iterations 99-123"
      puts "  #{$0} 8564 --step \"Extract Info\" --stats              # Aggregate analysis"
      puts "  #{$0} 8564 --step \"Extract Info\" --summary            # Compact overview"
      puts "  #{$0} 8564 --step \"Extract Info\" --where \"date=Unknown\"  # Filter by field"
      puts "  #{$0} 8564 --step \"Extract Info\" --fields date,thoughts   # Select result fields"
      puts "  #{$0} 8564 -o /tmp/run.json                         # Save to file"
      puts "  #{$0} 8564 --org \"Acme Medical\""
      exit 0
    end
  end

  parser.parse!

  if iteration && iterations_raw
    warn 'Error: --iteration and --iterations are mutually exclusive'
    exit 1
  end

  if stats && !step_name
    warn 'Error: --stats requires --step'
    exit 1
  end

  if iterations_raw && !iterations_raw.match?(/\A\d+-\d+\z/)
    warn 'Error: --iterations must be in format N-M (e.g., "99-123")'
    exit 1
  end

  # Parse iterations range into integers once
  iteration_min = nil
  iteration_max = nil
  if iterations_raw
    parts = iterations_raw.split('-', 2)
    iteration_min = parts[0].to_i
    iteration_max = parts[1].to_i
    if iteration_min > iteration_max
      warn "Error: --iterations min (#{parts[0]}) must be <= max (#{parts[1]})"
      exit 1
    end
  end

  if ARGV.empty?
    warn 'Error: run_id is required'
    warn
    warn parser.banner
    warn
    warn 'Run with --help for usage information'
    exit 1
  end

  run_id = CLIHelpers.parse_resource_id(ARGV.first, path_segment: 'runs')

  CLIHelpers.run_with_error_handling do
    inspector = RunInspector.new(
      run_id,
      step_name: step_name,
      iteration: iteration,
      iteration_min: iteration_min,
      iteration_max: iteration_max,
      output_path: output_path,
      stats: stats,
      compact: compact,
      fields: fields,
      where_filters: where_filters,
      base_url: base_url,
      org_name: org_name
    )
    inspector.run
  end
end
