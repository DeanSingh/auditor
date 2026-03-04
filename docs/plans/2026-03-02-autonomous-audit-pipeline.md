# Autonomous Audit Pipeline Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable Claude Code to autonomously download project files from Workflow Labs and run end-to-end audits via the `/audit` skill.

**Architecture:** CLI download script (`bin/download_project.rb`) using Ruby stdlib `net/http` to call Workflow Labs' GraphQL API. Auth config stored in `~/.config/auditor/config`. The `/audit` skill gets a new Step 0 that invokes the script before the existing pipeline.

**Tech Stack:** Ruby 3.0+ (stdlib only — net/http, json, fileutils, optparse, uri), Workflow Labs GraphQL API

---

### Task 1: Create Auth Config and Config Loader

Build the config infrastructure first — everything else depends on it.

**Files:**
- Create: `lib/config.rb`
- Create: `bin/test_config.rb`

**Step 1: Create `lib/` directory**

Run: `mkdir -p ~/git/auditor/lib`

**Step 2: Write the failing test**

Create `bin/test_config.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

require_relative '../lib/config'

class ConfigTest < Minitest::Test
  def setup
    @original_env = {}
    %w[WORKFLOW_API_TOKEN WORKFLOW_ORG_ID WORKFLOW_BASE_URL].each do |key|
      @original_env[key] = ENV[key]
      ENV.delete(key)
    end
    @tmpdir = Dir.mktmpdir
  end

  def teardown
    @original_env.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    FileUtils.rm_rf(@tmpdir)
  end

  def test_reads_token_from_env
    ENV["WORKFLOW_API_TOKEN"] = "test-token-123"
    config = AuditorConfig.new
    assert_equal "test-token-123", config.token
  end

  def test_reads_org_id_from_env
    ENV["WORKFLOW_ORG_ID"] = "42"
    config = AuditorConfig.new
    assert_equal "42", config.org_id
  end

  def test_reads_from_config_file
    config_path = File.join(@tmpdir, "config")
    File.write(config_path, "token=file-token-456\norg_id=99\nbase_url=https://test.ing\n")
    config = AuditorConfig.new(config_path: config_path)
    assert_equal "file-token-456", config.token
    assert_equal "99", config.org_id
    assert_equal "https://test.ing", config.base_url
  end

  def test_env_overrides_config_file
    config_path = File.join(@tmpdir, "config")
    File.write(config_path, "token=file-token\norg_id=1\n")
    ENV["WORKFLOW_API_TOKEN"] = "env-token"
    config = AuditorConfig.new(config_path: config_path)
    assert_equal "env-token", config.token
    assert_equal "1", config.org_id
  end

  def test_default_base_url
    config = AuditorConfig.new(config_path: "/nonexistent")
    assert_equal "https://workflow.ing", config.base_url
  end

  def test_missing_token_raises
    config = AuditorConfig.new(config_path: "/nonexistent")
    error = assert_raises(AuditorConfig::MissingConfigError) { config.token! }
    assert_match(/token/i, error.message)
  end

  def test_missing_org_id_raises
    ENV["WORKFLOW_API_TOKEN"] = "some-token"
    config = AuditorConfig.new(config_path: "/nonexistent")
    error = assert_raises(AuditorConfig::MissingConfigError) { config.org_id! }
    assert_match(/org_id/i, error.message)
  end

  def test_skips_blank_lines_and_comments
    config_path = File.join(@tmpdir, "config")
    File.write(config_path, "# Auth config\ntoken=abc\n\norg_id=7\n# end\n")
    config = AuditorConfig.new(config_path: config_path)
    assert_equal "abc", config.token
    assert_equal "7", config.org_id
  end
end
```

**Step 3: Run test to verify it fails**

Run: `cd ~/git/auditor && ruby bin/test_config.rb`
Expected: LoadError — `cannot load such file -- ../lib/config`

**Step 4: Write the implementation**

Create `lib/config.rb`:

```ruby
# frozen_string_literal: true

# Reads auth configuration for the Workflow Labs API.
#
# Priority: environment variables > config file > defaults.
#
# Config file format (~/.config/auditor/config):
#   token=<api_token>
#   org_id=<organization_id>
#   base_url=https://workflow.ing
class AuditorConfig
  class MissingConfigError < StandardError; end

  DEFAULT_CONFIG_PATH = File.expand_path("~/.config/auditor/config")
  DEFAULT_BASE_URL = "https://workflow.ing"

  def initialize(config_path: DEFAULT_CONFIG_PATH)
    @file_values = parse_config_file(config_path)
  end

  def token
    ENV["WORKFLOW_API_TOKEN"] || @file_values["token"]
  end

  def org_id
    ENV["WORKFLOW_ORG_ID"] || @file_values["org_id"]
  end

  def base_url
    ENV["WORKFLOW_BASE_URL"] || @file_values["base_url"] || DEFAULT_BASE_URL
  end

  # Bang methods raise if the value is missing — use these in scripts.
  def token!
    token || raise(MissingConfigError, missing_message("token", "WORKFLOW_API_TOKEN"))
  end

  def org_id!
    org_id || raise(MissingConfigError, missing_message("org_id", "WORKFLOW_ORG_ID"))
  end

  private

  def parse_config_file(path)
    return {} unless File.exist?(path)

    File.readlines(path).each_with_object({}) do |line, hash|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      key, value = line.split("=", 2)
      hash[key.strip] = value&.strip
    end
  end

  def missing_message(field, env_var)
    <<~MSG.strip
      Missing #{field}. Set it via:
        1. Environment variable: export #{env_var}=<value>
        2. Config file: echo "#{field}=<value>" >> #{DEFAULT_CONFIG_PATH}

      To create a token, run in the Workflow Labs Rails console:
        user = User.find_by(email: "your@email.com")
        auth = Authentication.create!(user: user, ip: "127.0.0.1")
        puts auth.token
    MSG
  end
end
```

**Step 5: Run tests to verify they pass**

Run: `cd ~/git/auditor && ruby bin/test_config.rb`
Expected: All 8 tests pass

**Step 6: Commit**

```bash
cd ~/git/auditor
git add lib/config.rb bin/test_config.rb
git commit -m "Add config loader for Workflow Labs API auth"
```

---

### Task 2: Build GraphQL Client

A small HTTP client that sends GraphQL queries to Workflow Labs and handles auth.

**Files:**
- Create: `lib/workflow_client.rb`
- Create: `bin/test_workflow_client.rb`

**Step 1: Write the failing test**

Create `bin/test_workflow_client.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'webrick'
require 'json'

require_relative '../lib/workflow_client'
require_relative '../lib/config'

class WorkflowClientTest < Minitest::Test
  def setup
    @server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new("/dev/null"), AccessLog: [])
    @port = @server.config[:Port]
    @base_url = "http://localhost:#{@port}"

    # Capture requests for assertion
    @received_requests = []

    @server.mount_proc("/graphql") do |req, res|
      @received_requests << req
      body = JSON.parse(req.body)
      res.content_type = "application/json"

      if body["query"].include?("project")
        res.body = JSON.generate({
          "data" => {
            "project" => {
              "id" => "50",
              "name" => "Eric Reed",
              "claimantDob" => "1985-03-15",
              "documents" => [
                {
                  "id" => "1",
                  "name" => "COMPLETE_Reed_Eric_10.pdf",
                  "status" => "processed",
                  "file" => { "filename" => "COMPLETE_Reed_Eric_10.pdf", "url" => "#{@base_url}/blob/1/file.pdf", "bytesize" => 1024, "type" => "application/pdf" }
                }
              ],
              "runs" => [
                {
                  "id" => "100",
                  "status" => "succeeded",
                  "started" => "2026-03-01T10:00:00Z",
                  "finished" => "2026-03-01T10:05:00Z",
                  "workflow" => { "id" => "1", "name" => "Record Review" },
                  "files" => [
                    { "filename" => "medical_summary_indexed.docx", "url" => "#{@base_url}/blob/2/file.docx", "bytesize" => 2048, "type" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document" }
                  ],
                  "inputFiles" => []
                }
              ]
            }
          }
        })
      else
        res.status = 400
        res.body = JSON.generate({ "errors" => [{ "message" => "Unknown query" }] })
      end
    end

    Thread.new { @server.start }
  end

  def teardown
    @server.shutdown
  end

  def test_fetches_project_data
    client = WorkflowClient.new(base_url: @base_url, token: "test-token", org_id: "1")
    project = client.fetch_project("50")

    assert_equal "50", project["id"]
    assert_equal "Eric Reed", project["name"]
    assert_equal 1, project["documents"].length
    assert_equal 1, project["runs"].length
  end

  def test_sends_auth_headers
    client = WorkflowClient.new(base_url: @base_url, token: "my-secret-token", org_id: "42")
    client.fetch_project("50")

    req = @received_requests.first
    assert_equal "Bearer my-secret-token", req["Authorization"]
    assert_equal "42", req["X-Organization-Id"]
  end

  def test_raises_on_graphql_errors
    @server.mount_proc("/graphql") do |_req, res|
      res.content_type = "application/json"
      res.body = JSON.generate({ "errors" => [{ "message" => "Project not found" }] })
    end

    client = WorkflowClient.new(base_url: @base_url, token: "t", org_id: "1")
    error = assert_raises(WorkflowClient::GraphQLError) { client.fetch_project("999") }
    assert_match(/Project not found/, error.message)
  end

  def test_raises_on_http_error
    @server.mount_proc("/graphql") do |_req, res|
      res.status = 401
      res.body = "Unauthorized"
    end

    client = WorkflowClient.new(base_url: @base_url, token: "bad", org_id: "1")
    assert_raises(WorkflowClient::HTTPError) { client.fetch_project("50") }
  end
end
```

**Step 2: Run test to verify it fails**

Run: `cd ~/git/auditor && ruby bin/test_workflow_client.rb`
Expected: LoadError — `cannot load such file -- ../lib/workflow_client`

**Step 3: Write the implementation**

Create `lib/workflow_client.rb`:

```ruby
# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

# HTTP client for the Workflow Labs GraphQL API.
class WorkflowClient
  class GraphQLError < StandardError; end
  class HTTPError < StandardError; end

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

  def initialize(base_url:, token:, org_id:)
    @base_url = base_url
    @token = token
    @org_id = org_id
  end

  def fetch_project(project_id)
    result = execute(PROJECT_QUERY, variables: { id: project_id.to_s })
    result["project"]
  end

  # Download a file from a blob URL, following redirects (Active Storage → S3).
  # Returns the response body (binary string).
  def download_file(url)
    uri = URI(url)
    response = make_request(uri, :get)

    # Follow redirects (Active Storage redirects to S3 presigned URL)
    limit = 5
    while response.is_a?(Net::HTTPRedirection) && limit > 0
      uri = URI(response["location"])
      # Don't send auth headers to S3 — presigned URL has its own auth
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(Net::HTTP::Get.new(uri))
      end
      limit -= 1
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise HTTPError, "Download failed: #{response.code} #{response.message} for #{url}"
    end

    response.body
  end

  private

  def execute(query, variables: {})
    uri = URI("#{@base_url}/graphql")
    body = JSON.generate({ query: query, variables: variables })

    response = make_request(uri, :post, body: body)

    unless response.is_a?(Net::HTTPSuccess)
      raise HTTPError, "HTTP #{response.code}: #{response.body}"
    end

    data = JSON.parse(response.body)

    if data["errors"]&.any?
      messages = data["errors"].map { |e| e["message"] }.join("; ")
      raise GraphQLError, messages
    end

    data["data"]
  end

  def make_request(uri, method, body: nil)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      request = case method
                when :get then Net::HTTP::Get.new(uri)
                when :post then Net::HTTP::Post.new(uri)
                end

      request["Authorization"] = "Bearer #{@token}"
      request["X-Organization-Id"] = @org_id
      request["Content-Type"] = "application/json"
      request.body = body if body

      http.request(request)
    end
  end
end
```

**Step 4: Run tests to verify they pass**

Run: `cd ~/git/auditor && ruby bin/test_workflow_client.rb`
Expected: All 4 tests pass

**Step 5: Commit**

```bash
cd ~/git/auditor
git add lib/workflow_client.rb bin/test_workflow_client.rb
git commit -m "Add GraphQL client for Workflow Labs API"
```

---

### Task 3: Build the Download Script

The main CLI script that orchestrates fetching project data and downloading files.

**Files:**
- Create: `bin/download_project.rb`

**Step 1: Write the script**

Create `bin/download_project.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'fileutils'

require_relative '../lib/config'
require_relative '../lib/workflow_client'

# Downloads project files from Workflow Labs and sets up a case directory.
class ProjectDownloader
  def initialize(project_id, case_name: nil, base_url: nil)
    @project_id = project_id
    @case_name_override = case_name
    @config = AuditorConfig.new
    @base_url = base_url || @config.base_url

    @client = WorkflowClient.new(
      base_url: @base_url,
      token: @config.token!,
      org_id: @config.org_id!
    )
  end

  def run
    puts "=== Downloading Project #{@project_id} ==="
    puts

    # Fetch project data
    print "Fetching project data... "
    project = @client.fetch_project(@project_id)
    puts "✓ #{project['name']}"
    puts

    # Determine case name
    case_name = @case_name_override || derive_case_name(project)
    puts "Case name: #{case_name}"

    # Setup case directory
    repo_root = File.dirname(File.dirname(File.absolute_path(__FILE__)))
    case_dir = File.join(repo_root, "cases", case_name)
    setup_case_dir(case_dir)
    puts "Case directory: #{case_dir}"
    puts

    downloaded = []

    # Download run output files (your indexed document)
    puts "Run output files:"
    latest_run = find_latest_successful_run(project["runs"])
    if latest_run
      latest_run["files"].each do |file|
        path = download_to(file, case_dir)
        downloaded << { type: "run_output", filename: file["filename"], path: path }
      end
    else
      puts "  (no successful runs found — skipping run outputs)"
    end
    puts

    # Download project documents (vendor files)
    puts "Project documents:"
    project["documents"].each do |doc|
      next unless doc["status"] == "processed"

      file = doc["file"]
      path = download_to(file, case_dir)
      downloaded << { type: "document", filename: file["filename"], path: path }
    end
    puts

    # Summary
    puts "=== Download Complete ==="
    puts "Case: #{case_name}"
    puts "Directory: #{case_dir}"
    puts "Files downloaded: #{downloaded.length}"
    downloaded.each do |d|
      puts "  [#{d[:type]}] #{d[:filename]}"
    end

    case_name
  end

  private

  def derive_case_name(project)
    # Try project name first (e.g., "Eric Reed" → "Reed_Eric")
    name = project["name"]
    if name && !name.strip.empty?
      parts = name.strip.split(/\s+/)
      if parts.length >= 2
        return "#{parts.last}_#{parts.first}"
      end
      return parts.first.gsub(/\s+/, "_")
    end

    # Fallback to timestamp
    Time.now.strftime("Case_%Y%m%d_%H%M%S")
  end

  def setup_case_dir(case_dir)
    FileUtils.mkdir_p(case_dir)
    %w[mappings reports ocr_cache].each do |subdir|
      FileUtils.mkdir_p(File.join(case_dir, subdir))
    end
  end

  def find_latest_successful_run(runs)
    runs
      .select { |r| r["status"] == "succeeded" }
      .max_by { |r| r["finished"] || "" }
  end

  def download_to(file_info, case_dir)
    filename = file_info["filename"]
    dest = File.join(case_dir, filename)
    bytesize = file_info["bytesize"]

    print "  Downloading #{filename} (#{format_bytes(bytesize)})... "

    begin
      data = @client.download_file(file_info["url"])
      File.binwrite(dest, data)
      puts "✓"
    rescue => e
      puts "✗ (#{e.message})"
      # Retry once
      print "  Retrying... "
      begin
        data = @client.download_file(file_info["url"])
        File.binwrite(dest, data)
        puts "✓"
      rescue => e2
        puts "✗ FAILED (#{e2.message})"
        return nil
      end
    end

    dest
  end

  def format_bytes(bytes)
    return "unknown size" unless bytes

    if bytes < 1024
      "#{bytes} B"
    elsif bytes < 1024 * 1024
      "#{(bytes / 1024.0).round(1)} KB"
    else
      "#{(bytes / (1024.0 * 1024)).round(1)} MB"
    end
  end
end

# Main execution
if __FILE__ == $0
  case_name = nil
  base_url = nil

  OptionParser.new do |opts|
    opts.banner = "Download project files from Workflow Labs\n\n"
    opts.banner += "Usage: #{$0} [options] <project_id>"

    opts.on("--case NAME", "Override case name (default: derived from project name)") do |name|
      case_name = name
    end

    opts.on("--base-url URL", "Workflow Labs base URL (default: https://workflow.ing)") do |url|
      base_url = url
    end

    opts.on("-h", "--help", "Show this help message") do
      puts opts
      puts
      puts "Arguments:"
      puts "  project_id    The Workflow Labs project ID (number)"
      puts
      puts "Examples:"
      puts "  #{$0} 50"
      puts "  #{$0} --case \"Reed_Eric\" 50"
      puts "  #{$0} --base-url http://localhost:3000 50"
      puts
      puts "Auth Configuration:"
      puts "  Set WORKFLOW_API_TOKEN and WORKFLOW_ORG_ID environment variables, or"
      puts "  create ~/.config/auditor/config with:"
      puts "    token=<your_api_token>"
      puts "    org_id=<your_organization_id>"
      puts "    base_url=https://workflow.ing"
      exit 0
    end
  end.parse!

  if ARGV.empty?
    puts "Error: project_id is required"
    puts "Run with --help for usage"
    exit 1
  end

  project_id = ARGV[0]

  # Also accept a URL and extract the ID
  if project_id =~ %r{/projects/(\d+)}
    project_id = $1
  end

  begin
    downloader = ProjectDownloader.new(project_id, case_name: case_name, base_url: base_url)
    downloader.run
  rescue AuditorConfig::MissingConfigError => e
    puts "Error: #{e.message}"
    exit 1
  rescue WorkflowClient::GraphQLError => e
    puts "Error: GraphQL query failed — #{e.message}"
    exit 1
  rescue WorkflowClient::HTTPError => e
    puts "Error: HTTP request failed — #{e.message}"
    exit 1
  end
end
```

**Step 2: Make it executable**

Run: `chmod +x ~/git/auditor/bin/download_project.rb`

**Step 3: Test manually with a dry run** (no server needed — just test the arg parsing)

Run: `cd ~/git/auditor && ruby bin/download_project.rb --help`
Expected: Shows help text with usage, examples, auth config instructions

Run: `cd ~/git/auditor && ruby bin/download_project.rb`
Expected: Error "project_id is required"

Run: `cd ~/git/auditor && ruby bin/download_project.rb https://workflow.ing/dashboard/projects/50`
Expected: Error about missing token (proves URL parsing works)

**Step 4: Commit**

```bash
cd ~/git/auditor
git add bin/download_project.rb
git commit -m "Add download script for Workflow Labs project files"
```

---

### Task 4: Create API Token in Workflow Labs

One-time setup to create an auth token and config file.

**Files:**
- Create: `~/.config/auditor/config`

**Step 1: Create the token in Rails console**

Run in the Workflow Labs repo (`~/git/workflow`):

```bash
cd ~/git/workflow && bin/rails console
```

Then in the console:

```ruby
user = User.find_by(email: "dean@workflowlabs.com")  # adjust email
auth = Authentication.create!(user: user, ip: "127.0.0.1")
org = user.organizations.first
puts "Token: #{auth.token}"
puts "Org ID: #{org.id}"
```

Copy the token and org_id from the output.

**Step 2: Create the config file**

```bash
mkdir -p ~/.config/auditor
cat > ~/.config/auditor/config << 'EOF'
token=<paste_token_here>
org_id=<paste_org_id_here>
base_url=https://workflow.ing
EOF
chmod 600 ~/.config/auditor/config
```

**Step 3: Verify the config**

Run: `cd ~/git/auditor && ruby -e "require_relative 'lib/config'; c = AuditorConfig.new; puts c.token!; puts c.org_id!; puts c.base_url"`
Expected: Prints the token, org_id, and base URL without errors

**Step 4: No commit** (config file is outside the repo and contains secrets)

---

### Task 5: Integration Test — Download a Real Project

Test the full download flow against the running Workflow Labs instance.

**Step 1: Test against local dev server** (if running)

Run: `cd ~/git/auditor && ruby bin/download_project.rb --base-url http://localhost:3000 50`

Or against production:

Run: `cd ~/git/auditor && ruby bin/download_project.rb 50`

Expected output:
```
=== Downloading Project 50 ===

Fetching project data... ✓ Eric Reed

Case name: Reed_Eric
Case directory: /Users/deansingh/git/auditor/cases/Reed_Eric

Run output files:
  Downloading medical_summary_indexed.docx (X.X MB)... ✓

Project documents:
  Downloading COMPLETE_Reed_Eric_10.pdf (X.X MB)... ✓

=== Download Complete ===
Case: Reed_Eric
Directory: /Users/deansingh/git/auditor/cases/Reed_Eric
Files downloaded: 2
  [run_output] medical_summary_indexed.docx
  [document] COMPLETE_Reed_Eric_10.pdf
```

**Step 2: Verify the files were downloaded correctly**

Run: `ls -la ~/git/auditor/cases/Reed_Eric/`
Expected: Should show the DOCX and PDF files with non-zero sizes

Run: `file ~/git/auditor/cases/Reed_Eric/medical_summary_indexed.docx`
Expected: Should identify as a Microsoft Word document (not HTML or error text)

Run: `file ~/git/auditor/cases/Reed_Eric/COMPLETE_Reed_Eric_10.pdf`
Expected: Should identify as a PDF document

**Step 3: Debug and fix any issues**

Common issues to watch for:
- **401 Unauthorized**: Token is wrong or expired. Recreate in Rails console.
- **Redirect not followed**: Active Storage blob URL returns 302. Make sure `download_file` follows redirects.
- **Wrong org_id**: GraphQL returns empty project. Check org_id matches.
- **SSL errors**: If testing against localhost without HTTPS, use `--base-url http://localhost:3000`.

---

### Task 6: Update Claude Code Permissions

Add the new script to `.claude/settings.local.json` so Claude Code can run it.

**Files:**
- Modify: `.claude/settings.local.json`

**Step 1: Add permission for the new script**

Add these entries to the `allow` array in `.claude/settings.local.json`:

```json
"Bash(./bin/download_project.rb:*)",
"Bash(/Users/deansingh/git/auditor/bin/download_project.rb:*)"
```

**Step 2: Commit**

```bash
cd ~/git/auditor
git add .claude/settings.local.json
git commit -m "Add permission for download_project.rb script"
```

---

### Task 7: Update the `/audit` Skill

Add Step 0 for project download and support QA-only mode.

**Files:**
- Modify: `~/.claude/skills/audit/SKILL.md`

**Step 1: Read the current skill file** (already read above — for reference)

**Step 2: Add Step 0 and update argument handling**

Insert the following **before** the existing `## Step 1: Case Selection` section. Also update the frontmatter `argument-hint`.

Changes to the frontmatter:

```yaml
---
name: audit
description: Analyze medical records audit cases. Use when user wants to review discrepancy reports, investigate missing records, or analyze reconciliation results from the auditor pipeline.
disable-model-invocation: true
argument-hint: Project ID, URL, or case name
---
```

Insert new section after `## Case Structure` and before `## Step 1`:

```markdown
## Step 0: Project Download (if project ID or URL provided)

If `$ARGUMENTS` is a number or contains a workflow.ing URL, download the project files first.

1. **Extract the project ID:**
   - Number (e.g., `50`): use directly
   - URL (e.g., `https://workflow.ing/dashboard/projects/50`): extract ID from path
   - URL with report review (e.g., `.../projects/50/report-review/8553`): extract project ID (50)

2. **Run the download script:**
   ```bash
   cd ~/git/auditor && ruby bin/download_project.rb <project_id>
   ```

3. **Read the output** to identify:
   - The case name (e.g., `Reed_Eric`)
   - What files were downloaded
   - Any errors

4. **Continue to Step 1** with the case name from the download output.

If `$ARGUMENTS` is NOT a number or URL (e.g., "Amy_Smart"), skip Step 0 and go to Step 1.
```

Update `## Step 1: Case Selection` — change the first line:

```markdown
## Step 1: Case Selection

If `$ARGUMENTS` is provided (either directly or from Step 0), use it as the case name. Otherwise:
```

Add a new section after `## Step 2b: QA Log Comparison (when available)` and before `## Step 2c`:

```markdown
## Mode Detection

After loading the case, determine which mode to run:

**Full reconciliation mode** — if both `medical_summary_indexed.docx` (or .pdf) AND a `COMPLETE_*.pdf` exist:
- Run Steps 1–4 (existing pipeline) → then analysis
- Also run Step 2b if a `QA Log*.csv` exists

**QA-only mode** — if only `medical_summary_indexed.docx` exists (no COMPLETE PDF), or user says "QA only":
- Skip Steps 1–4 (no vendor comparison needed)
- Jump directly to Step 2b: QA Log Comparison
- Compare the QA reviewer's notes against the AI record review
- If no QA CSV exists, tell the user to export it from Google Sheets and place it in the case directory
```

**Step 3: Verify the skill loads correctly**

In the auditor repo, run `/audit --help` (or just `/audit`) and verify Claude Code sees the updated instructions including Step 0.

**Step 4: No git commit** (skill file is outside the auditor repo at `~/.claude/skills/`)

---

### Task 8: End-to-End Test

Run the full autonomous audit flow to verify everything works together.

**Step 1: Test with project download**

In the auditor repo, run: `/audit 50`

Expected behavior:
1. Claude Code sees `50` is a number → triggers Step 0
2. Runs `bin/download_project.rb 50`
3. Downloads files to `cases/Reed_Eric/`
4. Continues to Step 1 with case name `Reed_Eric`
5. Detects mode (full reconciliation if COMPLETE PDF present, QA-only if not)
6. Runs the appropriate pipeline

**Step 2: Test with URL**

Run: `/audit https://workflow.ing/dashboard/projects/50`

Expected: Same behavior — extracts project ID 50 from URL

**Step 3: Test QA-only mode**

1. Download project files: `ruby bin/download_project.rb 50`
2. Remove the COMPLETE PDF: `rm cases/Reed_Eric/COMPLETE_*.pdf`
3. Drop a QA CSV into the case directory
4. Run: `/audit Reed_Eric`
5. Expected: Skips reconciliation pipeline, goes straight to QA comparison

**Step 4: Test backward compatibility**

Run: `/audit Amy_Smart` (existing case with files already in place)
Expected: Works exactly as before — no download step triggered

---

## Task Summary

| Task | Description | Depends On |
|------|-------------|------------|
| 1 | Config loader (`lib/config.rb`) + tests | — |
| 2 | GraphQL client (`lib/workflow_client.rb`) + tests | Task 1 |
| 3 | Download script (`bin/download_project.rb`) | Tasks 1, 2 |
| 4 | Create API token + config file | Task 1 |
| 5 | Integration test — download a real project | Tasks 3, 4 |
| 6 | Update Claude Code permissions | Task 3 |
| 7 | Update `/audit` skill with Step 0 + mode detection | Task 3 |
| 8 | End-to-end test of full autonomous flow | All above |
