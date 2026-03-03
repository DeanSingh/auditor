# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'uri'
require 'json'

# HTTP client for the Workflow Labs GraphQL API.
#
# Enforces HTTPS for all non-localhost connections (HIPAA requirement).
# Never leaks credentials in error messages or to third-party hosts on redirect.
class WorkflowClient
  class GraphQLError < StandardError; end
  class HTTPError < StandardError; end
  class InsecureConnectionError < StandardError; end

  MAX_REDIRECTS = 5
  MAX_ERROR_LENGTH = 200

  ORGS_QUERY = <<~GRAPHQL
    query { organizations { id name current } }
  GRAPHQL

  GRAPHQL_QUERY = <<~GRAPHQL
    query GetProject($id: ID!) {
      project(id: $id) {
        id
        name
        claimantDob
        documents {
          id
          name
          status
          kind
          file { filename url bytesize type }
        }
        runs {
          id
          status
          started
          finished
          workflow { id name }
          files { filename url bytesize type }
          inputFiles { filename url bytesize type }
        }
      }
    }
  GRAPHQL

  RUN_SUMMARY_QUERY = <<~GRAPHQL
    query InspectRun($id: ID!) {
      run(id: $id) {
        id
        status
        started
        finished
        stats {
          executionCount
          stepCount
          failedExecutionCount
          succeededExecutionCount
        }
        workflow {
          name
          steps {
            id
            name
            kind
            priority
            action {
              ... on Action__Prompt {
                messages { role template }
              }
            }
          }
        }
        executions {
          id
          status
          step { name }
        }
      }
    }
  GRAPHQL

  RUN_EXECUTIONS_QUERY = <<~GRAPHQL
    query InspectRunExecutions($id: ID!, $filter: ExecutionFilterInput) {
      run(id: $id) {
        executions(filter: $filter) {
          iteration
          status
          output
          result
          prompt
          step { name }
          started
          finished
        }
      }
    }
  GRAPHQL

  def initialize(base_url:, token:, org_id:)
    @base_url = base_url.chomp('/')
    @token = token
    @org_id = org_id

    validate_url_security!(@base_url)
  end

  # Fetches the user's organizations.
  def fetch_organizations
    uri = URI("#{@base_url}/graphql")
    body = JSON.generate(query: ORGS_QUERY)
    response = post_json(uri, body)
    data = parse_response(response)
    data['organizations'] || []
  end

  # Fetches a project by ID via the GraphQL API.
  # Returns the project hash from the response data.
  def fetch_project(project_id)
    uri = URI("#{@base_url}/graphql")

    body = JSON.generate(
      query: GRAPHQL_QUERY,
      variables: { id: project_id }
    )

    response = post_json(uri, body)
    data = parse_response(response)

    data['project']
  end

  # Fetches a run summary (workflow structure + lightweight execution list).
  # Returns the run hash with workflow, steps, stats, and execution ids/statuses.
  def fetch_run_summary(run_id)
    uri = URI("#{@base_url}/graphql")
    body = JSON.generate(query: RUN_SUMMARY_QUERY, variables: { id: run_id })
    response = post_json(uri, body)
    data = parse_response(response)
    data['run']
  end

  # Fetches execution details for a specific step and iteration range.
  # Returns the run hash with filtered executions including full output/result.
  def fetch_run_executions(run_id, step_name:, iteration: nil, iteration_min: nil, iteration_max: nil)
    uri = URI("#{@base_url}/graphql")

    filter = { stepName: step_name }
    filter[:iteration] = iteration if iteration
    filter[:iterationMin] = iteration_min if iteration_min
    filter[:iterationMax] = iteration_max if iteration_max

    body = JSON.generate(
      query: RUN_EXECUTIONS_QUERY,
      variables: { id: run_id, filter: filter }
    )

    response = post_json(uri, body)
    data = parse_response(response)
    data['run']
  end

  # Downloads a file from the given URL, following redirects.
  # Active Storage URLs typically 302 to a presigned S3 URL.
  # Auth headers are stripped when redirecting to a different host.
  def download_file(url)
    validate_url_security!(url)

    uri = URI(url)
    original_host = uri.host
    redirects = 0

    loop do
      http = build_http(uri)
      request = Net::HTTP::Get.new(uri)

      # Only send auth headers to the original host (not S3, etc.)
      if uri.host == original_host
        request['Authorization'] = "Bearer #{@token}"
        request['X-Organization-Id'] = @org_id if @org_id
      end

      response = http.request(request)

      case response
      when Net::HTTPSuccess
        return response.body.b
      when Net::HTTPRedirection
        redirects += 1
        raise HTTPError, "Too many redirects (#{MAX_REDIRECTS})" if redirects > MAX_REDIRECTS

        location = response['Location']
        uri = URI(location)
        validate_url_security!(location)
      else
        raise HTTPError, "Download failed: HTTP #{response.code}"
      end
    end
  end

  private

  # POST JSON to the GraphQL endpoint with auth headers.
  def post_json(uri, body)
    http = build_http(uri)
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Authorization'] = "Bearer #{@token}"
    request['X-Organization-Id'] = @org_id if @org_id
    request.body = body

    response = http.request(request)

    case response
    when Net::HTTPSuccess
      response
    when Net::HTTPUnauthorized, Net::HTTPForbidden
      raise HTTPError, "Authentication failed (HTTP #{response.code})"
    else
      raise HTTPError, "HTTP #{response.code}: #{response.message}"
    end
  end

  # Parse JSON response body and check for GraphQL-level errors.
  def parse_response(response)
    data = JSON.parse(response.body)

    if data['errors']&.any?
      message = data['errors'].map { |e| e['message'] }.join('; ')
      raise GraphQLError, sanitize_error(message)
    end

    data['data']
  end

  # Truncate error messages to avoid leaking PHI (patient names, DOBs, etc.).
  def sanitize_error(message)
    return message if message.length <= MAX_ERROR_LENGTH

    "#{message[0...MAX_ERROR_LENGTH]}..."
  end

  # Validate that a URL uses HTTPS, with an exception for localhost/127.0.0.1.
  def validate_url_security!(url)
    uri = URI(url)
    return if uri.scheme == 'https'
    return if localhost?(uri.host)

    raise InsecureConnectionError,
          "HTTPS required for non-localhost connections (got #{uri.scheme}://#{uri.host})"
  end

  def localhost?(host)
    host == 'localhost' || host == '127.0.0.1'
  end

  def build_http(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    if http.use_ssl?
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    end
    http.open_timeout = 10
    http.read_timeout = 30
    http
  end
end
