# frozen_string_literal: true

require 'spec_helper_acceptance'

RSpec.context 'when checking idempotency' do
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

  compatible_agents.each do |agent|
    it "ensures idempotency on #{agent}" do
      expect { verify_idempotency(agent) }.not_to raise_error
    end
  end

  def verify_idempotency(agent)
    create_cron_for_idempotency(agent)
    verify_idempotency_cron_entry(agent)
    verify_cron_is_not_recreated(agent)
  end

  def create_cron_for_idempotency(agent)
    step 'Cron: basic - verify that it can be created'
    apply_manifest_on(agent, idempotency_manifest).tap do |result|
      expect(result.stdout).to match(%r{ensure: created})
    end
  end

  def verify_idempotency_cron_entry(agent)
    result = run_cron_on(agent, :list, 'tstuser')
    expect(result.stdout).to match(%r{. . . . . .bin.true})
  end

  def verify_cron_is_not_recreated(agent)
    step 'Cron: basic - should not create again'
    result = apply_manifest_on(agent, idempotency_manifest)
    expect(result.stdout).not_to match(%r{ensure: created})
  end

  def idempotency_manifest
    'cron { "myjob": command => "/bin/true", user => "tstuser", hour => "*", minute => [1], ensure => present, environment => [],}'
  end
end
