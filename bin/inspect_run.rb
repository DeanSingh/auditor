#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative '../lib/config'
require_relative '../lib/workflow_client'

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
  MAX_ERROR_LENGTH = 100

  def initialize(run_id, step_name: nil, iteration: nil, iterations: nil, base_url: nil, org_name: nil)
    @run_id = run_id
    @step_name = step_name
    @iteration = iteration
    @iterations = iterations

    config = AuditorConfig.new
    base = base_url || config.base_url

    org_id = resolve_org(base, config.token!, org_name) if org_name

    @client = WorkflowClient.new(
      base_url: base,
      token: config.token!,
      org_id: org_id
    )
  end

  def run
    if @step_name
      drill_down
    else
      summary
    end
  end

  private

  def summary
    data = @client.fetch_run_summary(@run_id)

    if data.nil?
      warn "Error: Run #{@run_id} not found"
      exit 1
    end

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

    output = {
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
    }

    puts JSON.pretty_generate(output)
  end

  def drill_down
    iter = @iteration
    iter_min = nil
    iter_max = nil

    if @iterations
      parts = @iterations.split('-', 2)
      iter_min = parts[0].to_i
      iter_max = parts[1].to_i
    end

    data = @client.fetch_run_executions(
      @run_id,
      step_name: @step_name,
      iteration: iter,
      iteration_min: iter_min,
      iteration_max: iter_max
    )

    if data.nil?
      warn "Error: Run #{@run_id} not found"
      exit 1
    end

    executions = (data['executions'] || []).map do |e|
      {
        'iteration' => e['iteration'],
        'status' => e['status'],
        'output' => e['output'],
        'result' => e['result'],
        'prompt' => e['prompt'],
        'started' => e['started'],
        'finished' => e['finished']
      }
    end

    output = {
      'step' => @step_name,
      'executions' => executions
    }

    puts JSON.pretty_generate(output)
  end

  def resolve_org(base_url, token, name)
    client = WorkflowClient.new(base_url: base_url, token: token, org_id: nil)
    orgs = client.fetch_organizations
    match = orgs.find { |o| o['name'].downcase == name.downcase }

    if match.nil?
      available = orgs.map { |o| o['name'] }.join(', ')
      warn "Error: Organization \"#{name}\" not found"
      warn "Available: #{available}"
      exit 1
    end

    match['id']
  end
end

# Main execution
if __FILE__ == $0
  step_name = nil
  iteration = nil
  iterations = nil
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
      iterations = range
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

  arg = ARGV.first
  run_id = if arg =~ %r{/runs/(\d+)}
             $1
           elsif arg =~ /\A\d+\z/
             arg
           else
             warn "Error: Could not parse run ID from: #{arg}"
             warn 'Expected a number (e.g., 8564) or a URL (e.g., https://workflow.ing/dashboard/runs/8564)'
             exit 1
           end

  begin
    inspector = RunInspector.new(
      run_id,
      step_name: step_name,
      iteration: iteration,
      iterations: iterations,
      base_url: base_url,
      org_name: org_name
    )
    inspector.run
  rescue AuditorConfig::MissingConfigError => e
    warn e.message
    exit 1
  rescue WorkflowClient::GraphQLError => e
    warn "Error: GraphQL query failed — #{e.message}"
    exit 1
  rescue WorkflowClient::HTTPError => e
    warn "Error: HTTP request failed — #{e.message}"
    exit 1
  rescue WorkflowClient::InsecureConnectionError => e
    warn "Error: #{e.message}"
    exit 1
  rescue StandardError => e
    msg = "#{e.class}: #{e.message}"
    msg = "#{msg[0...100]}..." if msg.length > 100
    warn "Unexpected error: #{msg}"
    exit 1
  end
end
