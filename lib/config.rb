# frozen_string_literal: true

# Reads Workflow Labs API credentials from environment variables and config file.
#
# Priority: environment variables > config file > defaults
#
# Config file location: ~/.config/auditor/config
# Format: key=value, one per line. Blank lines and # comments are ignored.
class AuditorConfig
  class MissingConfigError < StandardError; end

  DEFAULT_BASE_URL = 'https://workflow.ing'
  DEFAULT_CONFIG_PATH = File.expand_path('~/.config/auditor/config')

  ENV_VARS = {
    token: 'WORKFLOW_API_TOKEN',
    org_id: 'WORKFLOW_ORG_ID',
    base_url: 'WORKFLOW_BASE_URL'
  }.freeze

  def initialize(config_path: DEFAULT_CONFIG_PATH)
    @config_path = config_path
    @file_values = parse_config_file
  end

  def token
    env_or_file(:token)
  end

  def org_id
    env_or_file(:org_id)
  end

  def base_url
    env_or_file(:base_url) || DEFAULT_BASE_URL
  end

  def token!
    token || raise(MissingConfigError, missing_message(:token))
  end

  private

  def env_or_file(key)
    env_val = ENV[ENV_VARS[key]]
    return env_val if env_val && !env_val.empty?

    @file_values[key.to_s]
  end

  def parse_config_file
    return {} unless File.exist?(@config_path)

    check_file_permissions

    values = {}
    File.foreach(@config_path) do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')

      key, value = line.split('=', 2)
      values[key.strip] = value&.strip
    end
    values
  end

  def check_file_permissions
    mode = File.stat(@config_path).mode & 0o777
    return if mode <= 0o600

    warn "WARNING: Config file permissions are too open (#{format('%04o', mode)}). " \
         "Run: chmod 600 #{@config_path}"
  end

  def missing_message(key)
    env_var = ENV_VARS[key]
    <<~MSG.strip
      Missing #{key}. Set it via:

        1. Environment variable: export #{env_var}=<value>
        2. Config file: echo "#{key}=<value>" >> ~/.config/auditor/config

      To create an API token, run in the Workflow Labs Rails console:
        user = User.find_by(email: "your@email.com")
        auth = Authentication.create!(user: user, ip: "127.0.0.1")
        puts auth.token  # save this — it's only shown once
    MSG
  end
end
