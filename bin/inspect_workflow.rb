#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative '../lib/cli_helpers'

# Inspects workflows via the GraphQL API.
#
# Two modes:
#   List:   bin/inspect_workflow.rb [--query "search term"]
#   Detail: bin/inspect_workflow.rb <workflow_id>
#
# Outputs JSON to stdout for consumption by the auditor agent.
class WorkflowInspector
  def initialize(workflow_id: nil, query: nil, step_name: nil, output_path: nil, base_url: nil, org_name: nil)
    @workflow_id = workflow_id
    @query = query
    @step_name = step_name
    @output_path = output_path

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
    if @workflow_id
      detail
    else
      list
    end
  end

  private

  def list
    workflows = @client.fetch_workflows(query: @query)
    emit({ 'workflows' => workflows })
  end

  def detail
    data = @client.fetch_workflow(@workflow_id)

    if data.nil?
      warn "Error: Workflow #{@workflow_id} not found"
      exit 1
    end

    steps = (data['steps'] || []).sort_by { |s| s['priority'] || 0 }.map do |step|
      format_step(step)
    end

    # --step filter: output just that step
    if @step_name
      match = steps.find { |s| s['name'].downcase == @step_name.downcase }
      if match.nil?
        warn "Error: Step \"#{@step_name}\" not found"
        warn "Available: #{steps.map { |s| s['name'] }.join(', ')}"
        exit 1
      end
      emit(match)
      return
    end

    emit({
      'workflow' => { 'id' => data['id'], 'name' => data['name'] },
      'steps' => steps
    })
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

  # Flatten action details so consumers don't have to dig through raw GraphQL structure.
  # Prompt messages get merged into a readable "prompt_template" string.
  def format_step(step)
    entry = step.slice('name', 'kind', 'priority')
    action = step['action'] || {}

    case step['kind']
    when 'PROMPT'
      entry['model'] = action['model']
      entry['temperature'] = action['temperature']
      entry['format'] = action['format']
      messages = action['messages'] || []
      entry['prompt_template'] = messages.map { |m| "#{m['role']}:\n#{m['template']}" }.join("\n\n")
    when 'ITERATOR'
      entry['iterator'] = action.slice('kind', 'overKey', 'untilKey', 'iterationLimit', 'timesIterations',
                                       'batchSize', 'concurrent', 'concurrency')
    when 'CODE'
      entry['code'] = action['template']
    when 'FORMATTER'
      entry['template'] = action['template']
      entry['json'] = action['json']
    end

    entry
  end
end

# Main execution
if __FILE__ == $0
  query_filter = nil
  step_name = nil
  output_path = nil
  base_url = nil
  org_name = nil

  parser = OptionParser.new do |opts|
    opts.banner = "Inspect workflows via the GraphQL API\n\n"
    opts.banner += "Usage: #{$0} [workflow_id] [options]\n"
    opts.banner += "       #{$0} [workflow_url] [options]"

    opts.separator ''
    opts.separator 'Options:'

    opts.on('--query SEARCH', 'Filter workflows by name (list mode only)') do |q|
      query_filter = q
    end

    opts.on('--step NAME', 'Show only this step (detail mode only)') do |name|
      step_name = name
    end

    opts.on('-o', '--output FILE', 'Write JSON to file instead of stdout') do |path|
      output_path = path
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
      puts '  List (no ID):      Lists all workflows (optionally filtered by --query)'
      puts '  Detail (with ID):  Shows workflow steps and their configuration'
      puts
      puts 'Examples:'
      puts "  #{$0}                                              # List all workflows"
      puts "  #{$0} --query \"Record Review\"                      # Search by name"
      puts "  #{$0} 42                                            # Detail view"
      puts "  #{$0} https://workflow.ing/dashboard/workflows/42   # Detail (URL)"
      puts "  #{$0} 42 --step \"Extract info\"                        # Single step detail"
      puts "  #{$0} 42 -o /tmp/workflow.json                        # Save to file"
      puts "  #{$0} --org \"Acme Medical\"                          # List with org"
      exit 0
    end
  end

  parser.parse!

  workflow_id = nil
  if ARGV.any?
    workflow_id = CLIHelpers.parse_resource_id(ARGV.first, path_segment: 'workflows')
  end

  CLIHelpers.run_with_error_handling do
    inspector = WorkflowInspector.new(
      workflow_id: workflow_id,
      query: query_filter,
      step_name: step_name,
      output_path: output_path,
      base_url: base_url,
      org_name: org_name
    )
    inspector.run
  end
end
