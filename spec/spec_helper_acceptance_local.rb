# frozen_string_literal: true

require 'securerandom'
require 'shellwords'
require_relative 'acceptance/lib/cron_core_litmus_manifest_helpers'

LitmusAcceptanceHost = Struct.new(:target, :platform) do
  def tmpfile(prefix)
    safe_prefix = prefix.gsub(%r{[^a-zA-Z0-9_-]}, '_')
    File.join('/tmp', "#{safe_prefix}_#{Process.pid}_#{SecureRandom.hex(6)}")
  end
end

module CronCoreLitmusAcceptanceHelpers
  include PuppetLitmus
  include CronCoreLitmusManifestHelpers

  def litmus_host
    target = ENV['TARGET_HOST'] || 'litmus_localhost'
    inventory = if File.file?('spec/fixtures/litmus_inventory.yaml')
                  inventory_hash_from_inventory_file
                else
                  localhost_inventory_hash
                end
    facts = facts_from_node(inventory, target) || {}
    LitmusAcceptanceHost.new(target, facts['platform'] || 'linux')
  end

  def agents
    [litmus_host]
  end

  def compatible_agents
    agents.reject { |agent| agent['platform'].match?(%r{windows|eos-}) }
  end

  def on(_host, command, options = {})
    command = add_environment(command, options.fetch(:environment, {}))
    result = run_shell(command, expect_failures: true)
    assert_exit_code(result, command, options.fetch(:acceptable_exit_codes, [0]))

    yield result if block_given?
    result
  end

  def apply_manifest_on(_host, manifest, options = {})
    apply_manifest(manifest, options)
  end

  def create_remote_file(_host, destination, content)
    write_file(content, destination)
  end

  def remote_tmpdir(host, prefix)
    safe_prefix = prefix.gsub(%r{[^a-zA-Z0-9_-]}, '_')
    path = File.join('/tmp', "#{safe_prefix}_#{Process.pid}_#{SecureRandom.hex(6)}")
    on(host, "mkdir -p #{Shellwords.escape(path)}")
    path
  end

  def run_cron_on(host, action, username, content = nil)
    result = on(host, crontab_command(action, username, content), acceptable_exit_codes: (action == :add) ? [0] : [0, 1])
    yield result if block_given?
    result
  end

  def crontab_command(action, username, content)
    user = Shellwords.escape(username)
    return "crontab -u #{user} -l" if action == :list
    return "printf '%s\\n' #{Shellwords.escape(content)} | crontab -u #{user} -" if action == :add
    return "crontab -u #{user} -r" if action == :remove

    raise ArgumentError, "Unsupported crontab action: #{action}"
  end

  def user_present(host, username)
    apply_manifest_on(host, user_manifest(username, ensure: :present, managehome: false), catch_failures: true)
  end

  def user_absent(host, username)
    apply_manifest_on(host, user_manifest(username, ensure: :absent, managehome: false), catch_failures: true)
  end

  def step(message)
    puts message
    yield if block_given?
  end

  def fail_test(message)
    raise message
  end

  def assert_matching_arrays(expected, actual, message = '')
    expect(actual.sort).to(eq(expected.sort), message)
  end

  def clean(agent, options = {})
    options = { user: 'tstuser' }.merge(options)
    run_cron_on(agent, :remove, options[:user])
    apply_manifest_on(agent, user_manifest(options[:user], ensure: :absent, managehome: false), catch_failures: true)
  end

  def setup(agent, options = {})
    options = { user: 'tstuser' }.merge(options)
    apply_manifest_on(agent, user_manifest(options[:user], ensure: :present, managehome: false), catch_failures: true)
    apply_manifest_on(agent, %(case $facts['os']['name'] {
                                  centos, redhat, fedora, amazon: { $cron = 'cronie' }
                                  solaris: { $cron = 'core-os' }
                                  default: { $cron = 'cron' }
                                }
                                package { 'cron': name => $cron, ensure => present, }))
  end

  def crontab_entries_of(host, username)
    run_cron_on(host, :list, username).stdout.strip.lines.map(&:chomp).grep_v(%r{^#})
  end

  def puppet_resource(resource, title, *params)
    ['puppet', 'resource', Shellwords.escape(resource), Shellwords.escape(title), *params].join(' ')
  end

  private

  def add_environment(command, environment)
    prefix = environment.map { |key, value| "#{key}=#{Shellwords.escape(value.to_s)}" }.join(' ')
    prefix.empty? ? command : "#{prefix} #{command}"
  end

  def assert_exit_code(result, command, acceptable_codes)
    return if acceptable_codes.include?(result.exit_code)

    raise "Command failed with exit code #{result.exit_code}: #{command}"
  end
end

RSpec.configure do |config|
  config.include CronCoreLitmusAcceptanceHelpers
  config.extend CronCoreLitmusAcceptanceHelpers
end
