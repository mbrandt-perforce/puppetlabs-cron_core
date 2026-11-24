# frozen_string_literal: true

require 'spec_helper_acceptance'

RSpec.context 'when stripping whitespace from cron jobs' do
  before(:each) do
    compatible_agents.each do |agent|
      step 'ensure the user exists via puppet'
      setup(agent)
    end
  end

  after(:each) do
    compatible_agents.each do |agent|
      step 'Cron: cleanup'
      clean(agent)
    end
  end

  agents.each do |host|
    it 'removes leading and trailing whitespace from cron jobs' do
      expect { verify_cron_whitespace_handling(host) }.not_to raise_error
    end
  end

  def verify_cron_whitespace_handling(host)
    create_whitespace_cron_entry(host)
    verify_whitespace_is_stripped(host)
    verify_trailing_whitespace_is_ignored(host)
    verify_leading_whitespace_is_ignored(host)
  end

  def create_whitespace_cron_entry(host)
    step 'apply the resource on the host using puppet resource'
    on(host, puppet_resource('cron', 'crontest', 'user=tstuser', "command='   date > /dev/null    '", 'ensure=present')) do |result|
      expect(result.stdout).to match(%r{created})
    end
  end

  def verify_whitespace_is_stripped(host)
    step 'verify the added crontab entry has stripped whitespace'
    run_cron_on(host, :list, 'tstuser') do |result|
      expect(result.stdout).to match(%r{\* \* \* \* \* date > .dev.null})
    end
  end

  def verify_trailing_whitespace_is_ignored(host)
    step 'apply the resource with trailing whitespace and check nothing happened'
    on(host, puppet_resource('cron', 'crontest', 'user=tstuser', "command='date > /dev/null    '", 'ensure=present')) do |result|
      expect(result.stdout).not_to match(%r{ensure: created})
    end
  end

  def verify_leading_whitespace_is_ignored(host)
    step 'apply the resource with leading whitespace and check nothing happened'
    on(host, puppet_resource('cron', 'crontest', 'user=tstuser', "command='     date > /dev/null'", 'ensure=present')) do |result|
      expect(result.stdout).not_to match(%r{ensure: created})
    end
  end
end
