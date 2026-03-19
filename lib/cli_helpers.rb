# frozen_string_literal: true

require 'uri'
require_relative 'config'
require_relative 'workflow_client'

# Shared helpers for CLI scripts. Reduces duplication across bin/ scripts.
module CLIHelpers
  MAX_ERROR_LENGTH = 100

  # Parses a numeric resource ID from either a bare number or a URL.
  # Returns [id, extracted_base_url] — base_url is nil for bare IDs.
  #
  #   parse_resource_id("50", path_segment: "projects")
  #     => ["50", nil]
  #   parse_resource_id("https://workflow.ing/dashboard/projects/50", path_segment: "projects")
  #     => ["50", "https://workflow.ing"]
  #   parse_resource_id("http://localhost:3000/dashboard/runs/1910", path_segment: "runs")
  #     => ["1910", "http://localhost:3000"]
  #
  def self.parse_resource_id(arg, path_segment:)
    if arg =~ %r{\Ahttps?://}
      uri = URI.parse(arg)
      base = "#{uri.scheme}://#{uri.host}#{uri.port == uri.default_port ? '' : ":#{uri.port}"}"
      if arg =~ %r{/#{Regexp.escape(path_segment)}/(\d+)}
        [$1, base]
      else
        warn "Error: Could not parse #{path_segment.chomp('s')} ID from URL: #{arg}"
        exit 1
      end
    elsif arg =~ /\A\d+\z/
      [arg, nil]
    else
      warn "Error: Could not parse #{path_segment.chomp('s')} ID from: #{arg}"
      warn "Expected a number or a URL containing /#{path_segment}/<id>"
      exit 1
    end
  end

  # Finds the config environment that matches a base URL.
  # Returns nil if no match found.
  def self.env_for_url(base_url, config_path: AuditorConfig::DEFAULT_CONFIG_PATH)
    return nil unless base_url && File.exist?(config_path)

    data = YAML.load_file(config_path) || {}
    data.each do |env_name, values|
      next unless values.is_a?(Hash)

      return env_name if values['base_url'] == base_url
    end
    nil
  end

  # Resolves an organization name to its ID via the API.
  # Exits with a helpful error if the org is not found.
  def self.resolve_org_id(base_url:, token:, name:)
    client = WorkflowClient.new(base_url: base_url, token: token, org_id: nil)
    orgs = client.fetch_organizations
    match = orgs.find { |o| o['name'].casecmp?(name) }

    if match.nil?
      warn "Error: Organization \"#{name}\" not found"
      warn "Available: #{orgs.map { |o| o['name'] }.join(', ')}"
      exit 1
    end

    match['id']
  end

  # Auto-resolves org ID when --org is not provided.
  # If one org, uses it. If multiple, exits with a helpful list.
  def self.auto_resolve_org_id(base_url:, token:)
    client = WorkflowClient.new(base_url: base_url, token: token, org_id: nil)
    orgs = client.fetch_organizations

    case orgs.size
    when 0
      warn "Error: No organizations found for this token"
      exit 1
    when 1
      orgs.first['id']
    else
      warn "Error: Multiple organizations available. Specify one with --org:"
      orgs.each { |o| warn "  - #{o['name']}" }
      exit 1
    end
  end

  # Wraps a block with consistent error handling for CLI scripts.
  # Catches known exception types and exits with user-friendly messages.
  def self.run_with_error_handling
    yield
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
    warn "Unexpected error: #{truncate(msg, MAX_ERROR_LENGTH)}"
    exit 1
  end

  def self.truncate(str, max)
    return str if str.length <= max

    "#{str[0...max]}..."
  end
end
