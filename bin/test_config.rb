#!/usr/bin/env ruby
# frozen_string_literal: true

ENV['MT_NO_PLUGINS'] = '1'

require 'minitest/autorun'
require 'tempfile'
require 'fileutils'
require_relative '../lib/config'

class TestAuditorConfig < Minitest::Test
  def setup
    # Clear all env vars before each test
    ENV.delete('WORKFLOW_API_TOKEN')
    ENV.delete('WORKFLOW_ORG_ID')
    ENV.delete('WORKFLOW_BASE_URL')
  end

  def test_reads_token_from_env_var
    ENV['WORKFLOW_API_TOKEN'] = 'env_token_123'

    config = AuditorConfig.new(config_path: '/nonexistent/path')

    assert_equal 'env_token_123', config.token
  end

  def test_reads_org_id_from_env_var
    ENV['WORKFLOW_ORG_ID'] = 'env_org_456'

    config = AuditorConfig.new(config_path: '/nonexistent/path')

    assert_equal 'env_org_456', config.org_id
  end

  def test_reads_all_values_from_config_file
    config_file = Tempfile.new('auditor_config')
    config_file.write("token=file_token_abc\norg_id=file_org_789\nbase_url=https://custom.example.com\n")
    config_file.close
    File.chmod(0o600, config_file.path)

    config = AuditorConfig.new(config_path: config_file.path)

    assert_equal 'file_token_abc', config.token
    assert_equal 'file_org_789', config.org_id
    assert_equal 'https://custom.example.com', config.base_url
  ensure
    config_file&.unlink
  end

  def test_env_var_overrides_config_file
    config_file = Tempfile.new('auditor_config')
    config_file.write("token=file_token\norg_id=file_org\n")
    config_file.close
    File.chmod(0o600, config_file.path)

    ENV['WORKFLOW_API_TOKEN'] = 'env_token_override'
    ENV['WORKFLOW_ORG_ID'] = 'env_org_override'

    config = AuditorConfig.new(config_path: config_file.path)

    assert_equal 'env_token_override', config.token
    assert_equal 'env_org_override', config.org_id
  ensure
    config_file&.unlink
  end

  def test_default_base_url
    config = AuditorConfig.new(config_path: '/nonexistent/path')

    assert_equal 'https://workflow.ing', config.base_url
  end

  def test_missing_token_raises_with_helpful_message
    config = AuditorConfig.new(config_path: '/nonexistent/path')

    error = assert_raises(AuditorConfig::MissingConfigError) { config.token! }
    assert_includes error.message, 'WORKFLOW_API_TOKEN'
    assert_includes error.message, 'config/auditor/config'
    refute_includes error.message, 'token_', 'Error message must never include a token value'
  end

  def test_missing_org_id_returns_nil
    config = AuditorConfig.new(config_path: '/nonexistent/path')

    assert_nil config.org_id
  end

  def test_skips_blank_lines_and_comments_in_config_file
    config_file = Tempfile.new('auditor_config')
    config_file.write(<<~CONFIG)
      # This is a comment
      token=parsed_token

      # Another comment
      org_id=parsed_org

    CONFIG
    config_file.close
    File.chmod(0o600, config_file.path)

    config = AuditorConfig.new(config_path: config_file.path)

    assert_equal 'parsed_token', config.token
    assert_equal 'parsed_org', config.org_id
  ensure
    config_file&.unlink
  end

  def test_warns_on_insecure_file_permissions
    config_file = Tempfile.new('auditor_config')
    config_file.write("token=insecure_token\n")
    config_file.close
    File.chmod(0o644, config_file.path)

    stderr_output = capture_io do
      AuditorConfig.new(config_path: config_file.path)
    end[1]

    assert_includes stderr_output, 'WARNING'
    assert_includes stderr_output, 'chmod 600'
  ensure
    config_file&.unlink
  end
end
