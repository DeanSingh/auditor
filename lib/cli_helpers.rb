# frozen_string_literal: true

require_relative 'config'
require_relative 'workflow_client'

# Shared helpers for CLI scripts. Reduces duplication across bin/ scripts.
module CLIHelpers
  MAX_ERROR_LENGTH = 100

  # Parses a numeric resource ID from either a bare number or a URL.
  #
  #   parse_resource_id("50", path_segment: "projects")
  #     => "50"
  #   parse_resource_id("https://workflow.ing/dashboard/projects/50", path_segment: "projects")
  #     => "50"
  #
  def self.parse_resource_id(arg, path_segment:)
    if arg =~ %r{/#{Regexp.escape(path_segment)}/(\d+)}
      $1
    elsif arg =~ /\A\d+\z/
      arg
    else
      warn "Error: Could not parse #{path_segment.chomp('s')} ID from: #{arg}"
      warn "Expected a number or a URL containing /#{path_segment}/<id>"
      exit 1
    end
  end

  # Resolves an organization name to its ID via the API.
  # Exits with a helpful error if the org is not found.
  def self.resolve_org_id(base_url:, token:, name:)
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
    msg = "#{msg[0...MAX_ERROR_LENGTH]}..." if msg.length > MAX_ERROR_LENGTH
    warn "Unexpected error: #{msg}"
    exit 1
  end
end
