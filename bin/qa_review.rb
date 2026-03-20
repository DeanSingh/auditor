#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'csv'
require 'optparse'
require_relative '../lib/cli_helpers'
require_relative '../lib/qa_reviewer'

# Automated QA review of Medical Summary letters in a run.
#
# Usage:
#   bin/qa_review.rb <run_id>                          # Full JSON report
#   bin/qa_review.rb <run_id> --compact                 # Summary + flagged only
#   bin/qa_review.rb <run_id> --format csv              # CSV matching Xerses's format
#   bin/qa_review.rb <run_url> -o /tmp/qa_review.json
#
# HIPAA notes:
#   - Letter content may contain PHI — outputs to stdout only (no files unless -o)
#   - Error messages are truncated to avoid leaking PHI
class QAReviewCLI
  CSV_HEADERS = ['Provider', 'Pages', 'Category', 'DOS', 'Issues / Notes', 'Status', 'Time (min)'].freeze

  def initialize(run_id, output_path: nil, compact: false, format: 'json',
                 env: nil, base_url: nil, org_name: nil)
    @run_id = run_id
    @output_path = output_path
    @compact = compact
    @format = format

    config = AuditorConfig.new(env: env)
    base = base_url || config.base_url
    token = config.token!

    org_id = if org_name
               CLIHelpers.resolve_org_id(base_url: base, token: token, name: org_name)
             else
               CLIHelpers.auto_resolve_org_id(base_url: base, token: token)
             end

    @client = WorkflowClient.new(base_url: base, token: token, org_id: org_id)
  end

  def run
    reviewer = QAReviewer.new(client: @client)
    result = reviewer.review(@run_id)

    result.delete('findings') if @compact

    if @format == 'csv'
      emit_csv(result)
    else
      emit_json(result)
    end
  end

  private

  def emit_json(data)
    json = JSON.pretty_generate(data)
    write_output(json)
  end

  def emit_csv(data)
    findings = data['flagged_findings'] || data['findings'] || []
    csv = CSV.generate do |rows|
      rows << CSV_HEADERS
      findings.each do |f|
        rows << [
          f['provider'],
          f['pages'],
          f['category'],
          f['dos'],
          f['issues_notes'],
          f['status'],
          (f['time_ms'] / 60_000.0).round(2)
        ]
      end
    end
    write_output(csv)
  end

  def write_output(content)
    if @output_path
      File.write(@output_path, content)
      warn "Wrote #{content.bytesize} bytes to #{@output_path}"
    else
      puts content
    end
  end
end

if __FILE__ == $0
  output_path = nil
  compact = false
  format = 'json'
  env = nil
  base_url = nil
  org_name = nil

  parser = OptionParser.new do |opts|
    opts.banner = "Automated QA review of Medical Summary letters\n\n"
    opts.banner += "Usage: #{$0} <run_id> [options]\n"
    opts.banner += "       #{$0} <run_url> [options]"

    opts.separator ''
    opts.separator 'Options:'

    opts.on('-o', '--output FILE', 'Write output to file instead of stdout') do |path|
      output_path = path
    end

    opts.on('--compact', 'Output summary + flagged findings only (omit clean letters)') do
      compact = true
    end

    opts.on('--format FORMAT', %w[json csv], 'Output format: json (default) or csv') do |f|
      format = f
    end

    opts.on('--env ENV', 'Config environment: production (default) or local') do |e|
      env = e
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
      puts 'Checks:'
      puts '  DOS verification    — Compares letter dates against source page text'
      puts '  Content coverage    — Flags Extract Info findings missing from summary'
      puts '  Redundancy          — Detects duplicate letters (overlapping pages or similar text)'
      puts '  Provider availability — Notes when no provider name is available'
      puts
      puts 'Examples:'
      puts "  #{$0} 8564                                     # Full JSON report"
      puts "  #{$0} https://workflow.ing/dashboard/runs/8564  # From URL"
      puts "  #{$0} 8564 --compact                            # Flagged findings only"
      puts "  #{$0} 8564 --format csv                         # CSV (Xerses's QA log format)"
      puts "  #{$0} 8564 --format csv -o /tmp/qa_review.csv   # Save CSV to file"
      puts "  #{$0} 8564 --org \"Acme Medical\""
      exit 0
    end
  end

  parser.parse!

  if ARGV.empty?
    warn 'Error: run_id is required'
    warn
    warn parser.banner
    warn
    warn 'Run with --help for usage information'
    exit 1
  end

  run_id, url_base = CLIHelpers.parse_resource_id(ARGV.first, path_segment: 'runs')

  if env.nil? && url_base
    env = CLIHelpers.env_for_url(url_base)
  end

  CLIHelpers.run_with_error_handling do
    cli = QAReviewCLI.new(
      run_id,
      output_path: output_path,
      compact: compact,
      format: format,
      env: env,
      base_url: base_url || url_base,
      org_name: org_name
    )
    cli.run
  end
end
