# frozen_string_literal: true

require 'spec_helper_acceptance'

RSpec.context 'when removing crontab' do
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

  compatible_agents.each do |host|
    it 'removes existing crontabs' do
      expect { verify_crontab_removed(host) }.not_to raise_error
    end
  end

  def verify_crontab_removed(host)
    create_existing_cron_job(host)
    remove_cron_job(host)
    verify_cron_entry_absent(host)
  end

  def create_existing_cron_job(host)
    step 'create the existing job by hand...'
    run_cron_on(host, :add, 'tstuser', '* * * * * /bin/true')
  end

  def remove_cron_job(host)
    step 'apply the resource on the host using puppet resource'
    on(host, puppet_resource('cron', 'crontest', 'user=tstuser',
                             'command=/bin/true', 'ensure=absent')) do |result|
      expect(result.stdout).to match(%r{crontest\D+ensure:\s+removed})
    end
  end

  def verify_cron_entry_absent(host)
    step ' contains what you expected'
    run_cron_on(host, :list, 'tstuser') do |result|
      expect(result.stderr).not_to match(%r{/bin/true})
    end
  end
end
