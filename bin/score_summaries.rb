#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative '../lib/cli_helpers'
require_relative '../lib/summary_scorer'

# Scores Medical Summary quality across all letters in a run.
#
# Usage:
#   bin/score_summaries.rb <run_id>                    # Full scorecard
#   bin/score_summaries.rb <run_id> --compact           # Summary + flagged only
#   bin/score_summaries.rb <run_url> -o /tmp/scores.json
#
# HIPAA notes:
#   - Letter content may contain PHI — outputs to stdout only (no files unless -o)
#   - Error messages are truncated to avoid leaking PHI
class ScoreSummariesCLI
  def initialize(run_id, output_path: nil, compact: false,
                 env: nil, base_url: nil, org_name: nil)
    @run_id = run_id
    @output_path = output_path
    @compact = compact

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
    scorer = SummaryScorer.new(client: @client)
    result = scorer.score(@run_id)

    result.delete('letters') if @compact

    emit(result)
  end

  private

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

if __FILE__ == $0
  output_path = nil
  compact = false
  env = nil
  base_url = nil
  org_name = nil

  parser = OptionParser.new do |opts|
    opts.banner = "Score Medical Summary quality for a workflow run\n\n"
    opts.banner += "Usage: #{$0} <run_id> [options]\n"
    opts.banner += "       #{$0} <run_url> [options]"

    opts.separator ''
    opts.separator 'Options:'

    opts.on('-o', '--output FILE', 'Write JSON to file instead of stdout') do |path|
      output_path = path
    end

    opts.on('--compact', 'Output summary + flagged letters only (omit full letters list)') do
      compact = true
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
      puts 'Output:'
      puts '  JSON scorecard with per-letter pass/fail and aggregate stats.'
      puts '  Each letter is checked for: header format, date/provider consistency,'
      puts '  empty content, required sections, and content length.'
      puts
      puts 'Examples:'
      puts "  #{$0} 8564                                     # Full scorecard"
      puts "  #{$0} https://workflow.ing/dashboard/runs/8564  # From URL"
      puts "  #{$0} 8564 --compact                            # Summary + flagged only"
      puts "  #{$0} 8564 -o /tmp/scores.json                  # Save to file"
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
    cli = ScoreSummariesCLI.new(
      run_id,
      output_path: output_path,
      compact: compact,
      env: env,
      base_url: base_url || url_base,
      org_name: org_name
    )
    cli.run
  end
end
