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

  PROJECT_QUERY = <<~GRAPHQL
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
          pageCount
          processedPageCount
          lettersCount
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
        document {
          ... on RecordReview {
            lettersCount
            sourcePages { count }
          }
        }
        documentable
      }
    }
  GRAPHQL

  WORKFLOWS_QUERY = <<~GRAPHQL
    query ListWorkflows($query: String) {
      workflows(query: $query) {
        id
        name
      }
    }
  GRAPHQL

  WORKFLOW_DETAIL_QUERY = <<~GRAPHQL
    query GetWorkflow($id: ID!) {
      workflow(id: $id) {
        id
        name
        steps {
          id
          name
          kind
          priority
          action {
            ... on Action__Prompt {
              model
              temperature
              format
              messages { role template }
            }
            ... on Action__Iterator {
              kind
              overKey
              untilKey
              iterationLimit
              timesIterations
              batchSize
              concurrent
              concurrency
            }
            ... on Action__Code {
              template
            }
            ... on Action__Formatter {
              template
              json
            }
          }
        }
      }
    }
  GRAPHQL

  RUN_DOCUMENT_LETTERS_QUERY = <<~GRAPHQL
    query InspectRunDocumentLetters($id: ID!) {
      run(id: $id) {
        document {
          ... on RecordReview {
            lettersCount
            letters {
              id
              index
              date
              provider
              category
              subcategory
              pageCount
              pages { pageNumber }
            }
          }
        }
      }
    }
  GRAPHQL

  RUN_DOCUMENT_LETTERS_WITH_CONTENT_QUERY = <<~GRAPHQL
    query InspectRunDocumentLettersWithContent($id: ID!) {
      run(id: $id) {
        document {
          ... on RecordReview {
            lettersCount
            letters {
              id
              index
              date
              provider
              category
              subcategory
              pageCount
              pages { pageNumber }
              content
            }
          }
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
    @graphql_uri = URI("#{@base_url}/graphql")

    validate_url_security!(@base_url)
  end

  # Fetches the user's organizations.
  def fetch_organizations
    graphql(ORGS_QUERY, 'organizations') || []
  end

  # Fetches a project by ID.
  def fetch_project(project_id)
    graphql(PROJECT_QUERY, 'project', id: project_id)
  end

  # Fetches a run summary (workflow structure + lightweight execution list).
  def fetch_run_summary(run_id)
    graphql(RUN_SUMMARY_QUERY, 'run', id: run_id)
  end

  # Fetches execution details for a specific step and iteration range.
  def fetch_run_executions(run_id, step_name:, iteration: nil, iteration_min: nil, iteration_max: nil)
    filter = { stepName: step_name }
    filter[:iteration] = iteration if iteration
    filter[:iterationMin] = iteration_min if iteration_min
    filter[:iterationMax] = iteration_max if iteration_max

    graphql(RUN_EXECUTIONS_QUERY, 'run', id: run_id, filter: filter)
  end

  # Fetches document letters for a run via the RunDocument union type.
  def fetch_run_document_letters(run_id)
    graphql(RUN_DOCUMENT_LETTERS_QUERY, %w[run document letters], id: run_id)
  end

  # Fetches document letters with full content for scoring.
  def fetch_run_document_letters_with_content(run_id)
    graphql(RUN_DOCUMENT_LETTERS_WITH_CONTENT_QUERY, %w[run document letters], id: run_id)
  end

  # Fetches workflows, optionally filtered by search query.
  def fetch_workflows(query: nil)
    variables = query ? { query: query } : {}
    graphql(WORKFLOWS_QUERY, 'workflows', **variables) || []
  end

  # Fetches a single workflow by ID with full step details.
  def fetch_workflow(workflow_id)
    graphql(WORKFLOW_DETAIL_QUERY, 'workflow', id: workflow_id)
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

  # Executes a GraphQL query and digs into the response.
  # `result_path` can be a string key or an array of keys for nested access.
  # Additional keyword arguments are passed as GraphQL variables.
  def graphql(query, result_path, **variables)
    body = JSON.generate(query: query, variables: variables)
    response = post_json(@graphql_uri, body)
    data = parse_response(response)
    data.dig(*Array(result_path))
  end

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

  LOCALHOST_HOSTS = %w[localhost 127.0.0.1].freeze

  def localhost?(host)
    LOCALHOST_HOSTS.include?(host)
  end

  def build_http(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
    http.open_timeout = 10
    http.read_timeout = 30
    http
  end
end
