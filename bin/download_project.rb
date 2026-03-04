#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'time'
require_relative '../lib/cli_helpers'

# Downloads project files from Workflow Labs and sets up a local case directory.
#
# Fetches the latest successful run outputs (your indexed documents) and
# processed project documents (vendor COMPLETE PDFs), then organizes them
# into a case folder for pipeline processing.
#
# HIPAA notes:
#   - All downloaded files are chmod 0600 (owner-only access)
#   - Audit log records project IDs only — never filenames or case names (they contain patient names)
#   - Error messages are truncated to avoid leaking PHI
#   - stdout contains filenames for authorized-user verification; do not pipe to shared logs
class ProjectDownloader
  AUDIT_LOG_DIR = File.expand_path('~/.config/auditor')
  AUDIT_LOG_PATH = File.join(AUDIT_LOG_DIR, 'access.log')

  def initialize(project_id, case_name: nil, base_url: nil, org_name: nil)
    @project_id = project_id
    @case_name_override = case_name
    @config = AuditorConfig.new
    @base_url = base_url || @config.base_url

    # Resolve org by name if provided
    org_id = CLIHelpers.resolve_org_id(base_url: @base_url, token: @config.token!, name: org_name) if org_name

    @client = WorkflowClient.new(
      base_url: @base_url,
      token: @config.token!,
      org_id: org_id
    )
  end

  def run
    puts "=== Downloading Project #{@project_id} ==="
    puts

    # Step 1: Fetch project data
    print "  Fetching project data... "
    project = @client.fetch_project(@project_id)

    if project.nil?
      puts "✗"
      warn "Error: Project #{@project_id} not found"
      warn "Try: #{$0} --list-orgs   (then re-run with --org \"<name>\")"
      exit 1
    end
    puts "✓"

    # Step 2: Determine case name
    case_name = @case_name_override || derive_case_name(project)
    puts "  Case name: #{case_name}"

    # Step 3: Create case directory structure
    script_dir = File.dirname(File.absolute_path(__FILE__))
    repo_root = File.dirname(script_dir)
    case_dir = File.join(repo_root, 'cases', case_name)

    print "  Creating case directory... "
    FileUtils.mkdir_p(case_dir)
    %w[mappings reports ocr_cache].each do |subdir|
      FileUtils.mkdir_p(File.join(case_dir, subdir))
    end
    puts "✓"
    puts "  #{case_dir}"
    puts

    # Step 4: Download run output files (your indexed documents)
    runs = project['runs'] || []
    latest_run = find_latest_successful_run(runs)
    run_file_count = 0

    if latest_run
      run_files = latest_run['files'] || []
      puts "  Run outputs (#{run_files.length} files from run #{latest_run['id']}):"
      run_files.each do |file_info|
        if download_to(file_info, case_dir)
          run_file_count += 1
        end
      end
    else
      puts "  No successful runs found — skipping run outputs"
    end
    puts

    # Step 5: Download project documents (vendor COMPLETE PDFs)
    documents = project['documents'] || []
    processed_docs = documents.select { |d| d['status']&.downcase == 'processed' }
    doc_file_count = 0

    puts "  Project documents (#{processed_docs.length} processed):"
    if processed_docs.empty?
      puts "    (none)"
    else
      processed_docs.each do |doc|
        file_info = doc['file']
        next unless file_info

        if download_to(file_info, case_dir)
          doc_file_count += 1
        end
      end
    end
    puts

    # Step 6: Write audit log
    total_files = run_file_count + doc_file_count
    write_audit_log(@project_id, total_files, 'success')

    # Summary
    puts "=== Download Complete ==="
    puts "  Project:   #{@project_id}"
    puts "  Case:      #{case_name}"
    puts "  Directory: #{case_dir}"
    puts "  Files:     #{total_files} downloaded (#{run_file_count} run outputs, #{doc_file_count} documents)"
    puts
    puts "Next step:"
    puts "  bin/run_pipeline.rb --case \"#{case_name}\" <your_indexed> <their_indexed>"
  rescue StandardError => e
    # HIPAA: log failed access attempts too
    write_audit_log(@project_id, 0, 'error')
    raise
  end

  private

  # Derives a case name from the project name: "Eric Reed" -> "Reed_Eric"
  def derive_case_name(project)
    name = project['name']&.strip
    if name.nil? || name.empty?
      return Time.now.strftime('Case_%Y%m%d_%H%M%S')
    end

    parts = name.split(/\s+/)
    if parts.length >= 2
      # Reverse to LastName_FirstName
      parts.reverse.join('_')
    else
      parts.first
    end
  end

  # Finds the latest successful run, sorted by finished timestamp.
  def find_latest_successful_run(runs)
    succeeded = runs.select { |r| r['status']&.downcase == 'succeeded' }
    return nil if succeeded.empty?

    succeeded.max_by { |r| r['finished'] || '' }
  end

  # Downloads a single file to the case directory.
  # Sets chmod 0600 on the downloaded file (HIPAA: PHI files owner-only).
  # Retries once on failure.
  def download_to(file_info, case_dir)
    filename = file_info['filename']
    return false if filename.nil? || filename.strip.empty?

    # HIPAA: sanitize to prevent path traversal from API-supplied filenames
    filename = File.basename(filename)
    bytesize = file_info['bytesize']
    url = file_info['url']

    print "    Downloading #{filename} (#{format_bytes(bytesize)})... "

    attempts = 0
    begin
      attempts += 1
      data = @client.download_file(url)
      dest = File.join(case_dir, filename)
      File.binwrite(dest, data)
      File.chmod(0o600, dest)
      puts "✓"
      true
    rescue StandardError => e
      if attempts < 2
        retry
      end
      puts "✗"
      # Truncate error to avoid PHI leaks
      msg = e.message[0...CLIHelpers::MAX_ERROR_LENGTH]
      warn "      Error: #{msg}"
      false
    end
  end

  # Formats byte counts for human-readable display.
  def format_bytes(bytes)
    return '0 B' if bytes.nil? || bytes.zero?

    if bytes >= 1_048_576
      format('%.1f MB', bytes / 1_048_576.0)
    elsif bytes >= 1024
      format('%.1f KB', bytes / 1024.0)
    else
      "#{bytes} B"
    end
  end

  # Appends an access entry to the audit log.
  # HIPAA: logs project IDs and file counts only — never case names or filenames (they contain patient names).
  def write_audit_log(project_id, file_count, status)
    FileUtils.mkdir_p(AUDIT_LOG_DIR)
    File.chmod(0o700, AUDIT_LOG_DIR)

    timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    entry = "#{timestamp} | project_id=#{project_id} | files=#{file_count} | status=#{status}\n"

    File.open(AUDIT_LOG_PATH, 'a') do |f|
      f.write(entry)
    end

    File.chmod(0o600, AUDIT_LOG_PATH)
  end
end

# Main execution
if __FILE__ == $0
  require 'optparse'

  case_name = nil
  base_url = nil
  org_name = nil
  list_orgs = false

  parser = OptionParser.new do |opts|
    opts.banner = "Download project files from Workflow Labs\n\n"
    opts.banner += "Usage: #{$0} <project_id> [options]\n"
    opts.banner += "       #{$0} <project_url> [options]\n"
    opts.banner += "       #{$0} --list-orgs"

    opts.separator ''
    opts.separator 'Options:'

    opts.on('--case NAME', 'Override case name (default: derived from project name)') do |name|
      case_name = name
    end

    opts.on('--base-url URL', 'Override Workflow Labs base URL') do |url|
      base_url = url
    end

    opts.on('--org NAME', 'Organization name (use --list-orgs to see available)') do |name|
      org_name = name
    end

    opts.on('--list-orgs', 'List your organizations and exit') do
      list_orgs = true
    end

    opts.on('-h', '--help', 'Show this help message') do
      puts opts
      puts
      puts 'Arguments:'
      puts '  project_id      Numeric project ID (e.g., 50)'
      puts '  project_url     Full project URL (e.g., https://workflow.ing/dashboard/projects/50)'
      puts
      puts 'Examples:'
      puts "  #{$0} 50"
      puts "  #{$0} https://workflow.ing/dashboard/projects/50"
      puts "  #{$0} 50 --case \"Reed_Eric\""
      puts "  #{$0} 50 --org \"Acme Medical\"  # query a different organization"
      puts "  #{$0} 50 --base-url \"http://localhost:3000\""
      puts
      puts 'Auth configuration:'
      puts '  Set credentials via environment variables or config file (~/.config/auditor/config):'
      puts
      puts '    export WORKFLOW_API_TOKEN=<your_token>'
      puts '    export WORKFLOW_ORG_ID=<your_org_id>'
      puts
      puts '  Or add to ~/.config/auditor/config:'
      puts '    token=<your_token>'
      puts '    org_id=<your_org_id>'
      puts
      puts '  To create an API token, run in the Workflow Labs Rails console:'
      puts '    user = User.find_by(email: "your@email.com")'
      puts '    auth = Authentication.create!(user: user, ip: "127.0.0.1")'
      puts '    puts auth.token'
      puts
      puts 'Output:'
      puts '  Cases are stored in: ~/git/auditor/cases/<case_name>/'
      puts '    - mappings/     Page mapping files'
      puts '    - reports/      Reconciliation and discrepancy reports'
      puts '    - ocr_cache/    OCR results cache'
      puts
      puts 'Audit log: ~/.config/auditor/access.log'
      exit 0
    end
  end

  parser.parse!

  # List organizations and exit
  if list_orgs
    begin
      config = AuditorConfig.new
      client = WorkflowClient.new(
        base_url: base_url || config.base_url,
        token: config.token!,
        org_id: nil
      )
      orgs = client.fetch_organizations
      if orgs.empty?
        puts "No organizations found for this token."
      else
        puts "Your organizations:"
        puts
        orgs.each do |org|
          current = org['current'] ? ' (current)' : ''
          puts "  #{org['id']}  #{org['name']}#{current}"
        end
        puts
        puts "Usage: #{$0} <project_id> --org \"<name>\""
      end
    rescue AuditorConfig::MissingConfigError => e
      warn e.message
    rescue StandardError => e
      warn "Error: #{e.message[0...100]}"
    end
    exit 0
  end

  # Extract project ID from argument
  if ARGV.empty?
    warn 'Error: project_id is required'
    warn
    warn parser.banner
    warn
    warn "Run with --help for usage information"
    exit 1
  end

  project_id = CLIHelpers.parse_resource_id(ARGV.first, path_segment: 'projects')

  CLIHelpers.run_with_error_handling do
    downloader = ProjectDownloader.new(project_id, case_name: case_name, base_url: base_url, org_name: org_name)
    downloader.run
  end
end
