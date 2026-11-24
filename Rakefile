# frozen_string_literal: true

require 'bundler'
require 'yaml'
require 'puppet_litmus/rake_tasks' if Gem.loaded_specs.key? 'puppet_litmus'
require 'puppetlabs_spec_helper/rake_tasks'
require 'puppet-syntax/tasks/puppet-syntax' if Gem.loaded_specs.key? 'puppet-syntax'
require 'puppetlabs-syntax/tasks/puppetlabs-syntax' if Gem.loaded_specs.key? 'puppetlabs-syntax'
require 'puppet-strings/tasks' if Gem.loaded_specs.key? 'puppet-strings'

namespace :acceptance do
  desc 'Provision Docker, install Puppet and the module, run Litmus acceptance tests, and tear down targets'
  task :litmus, [:provision_set, :collection] do |_task, args|
    args = args.with_defaults(provision_set: 'default', collection: ENV.fetch('PUPPET_COLLECTION', 'puppet8'))
    Rake::Task['litmus:provision_install'].invoke(args[:provision_set], args[:collection])
    Rake::Task['litmus:acceptance:parallel'].invoke
  ensure
    if File.file?('spec/fixtures/litmus_inventory.yaml') && ENV['LITMUS_KEEP_TARGETS'] != 'true'
      inventory = YAML.load_file('spec/fixtures/litmus_inventory.yaml')
      targets = inventory.fetch('groups', []).flat_map { |group| group.fetch('targets', []) }
      Rake::Task['litmus:tear_down'].invoke unless targets.empty?
    end
  end
end

PuppetLint.configuration.send('disable_relative')
PuppetLint.configuration.send('disable_80chars')
PuppetLint.configuration.send('disable_140chars')
PuppetLint.configuration.send('disable_class_inherits_from_params_class')
PuppetLint.configuration.send('disable_autoloader_layout')
PuppetLint.configuration.send('disable_documentation')
PuppetLint.configuration.send('disable_single_quote_string_with_variables')
PuppetLint.configuration.fail_on_warnings = true
PuppetLint.configuration.ignore_paths = [".vendor/**/*.pp", ".bundle/**/*.pp", "pkg/**/*.pp", "spec/**/*.pp", "tests/**/*.pp", "types/**/*.pp", "vendor/**/*.pp"]

