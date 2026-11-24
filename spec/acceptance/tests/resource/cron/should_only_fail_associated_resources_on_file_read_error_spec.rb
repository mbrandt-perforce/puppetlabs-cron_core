# frozen_string_literal: true

require 'spec_helper_acceptance'

RSpec.context 'when Puppet cannot read a crontab file' do
  let(:username) { "pl#{rand(999_999).to_i}" }
  let(:failed_username) { "pl#{rand(999_999).to_i}" }

  before(:each) do
    compatible_agents.each do |agent|
      step "Create the users on #{agent}" do
        user_present(agent, username)
        user_present(agent, failed_username)
      end
    end
  end

  after(:each) do
    compatible_agents.each do |agent|
      step "Teardown -- Erase the users on #{agent}" do
        run_cron_on(agent, :remove, username)
        user_absent(agent, username)

        user_absent(agent, failed_username)
      end
    end
  end

  compatible_agents.each do |agent|
    it "onlies fail the associated resources on #{agent}" do
      expect { verify_associated_read_error(agent) }.not_to raise_error
    end
  end

  def verify_associated_read_error(agent)
    crontab_exe = find_crontab_executable(agent)
    stub_bin_dir, stub_exe = create_failed_user_crontab_stub(agent, crontab_exe)
    path_env_var = find_agent_path(agent)
    puppet_result = apply_read_error_manifest(agent, stub_bin_dir, stub_exe, path_env_var)
    verify_unreadable_user_failed(puppet_result)
    verify_readable_user_succeeded(puppet_result)
    verify_readable_user_crontab(agent)
  end

  def find_crontab_executable(agent)
    executable = nil
    step 'Find the crontab executable' do
      executable = on(agent, 'which crontab').stdout.chomp
    end
    executable
  end

  def create_failed_user_crontab_stub(agent, crontab_exe)
    bin_dir = remote_tmpdir(agent, 'stub_crontab_bin_dir')
    stub_exe = "#{bin_dir}/crontab"
    script = failed_user_stub_script(crontab_exe)
    create_remote_file(agent, stub_exe, script)
    on(agent, "chmod 777 #{bin_dir}")
    on(agent, "chmod 777 #{stub_exe}")
    [bin_dir, stub_exe]
  end

  def failed_user_stub_script(crontab_exe)
    <<~SCRIPT
      #!/usr/bin/env bash
      if [[ "$@" =~ #{failed_username} || "`id`" =~ #{failed_username} ]]; then
      echo "Mocking a FileReadError for the #{failed_username} user's crontab!"
      exit 1
      fi
      #{crontab_exe} $@
    SCRIPT
  end

  def find_agent_path(agent)
    path = nil
    step 'Get the value of the PATH environment variable' do
      path = on(agent, 'echo $PATH').stdout.chomp
    end
    path
  end

  def apply_read_error_manifest(agent, stub_bin_dir, stub_exe, path_env_var)
    result = nil
    step 'Add some cron entries with Puppet' do
      manifest_file = create_read_error_manifest(agent, stub_exe)
      result = execute_read_error_manifest(agent, stub_bin_dir, path_env_var, manifest_file)
    end
    result
  end

  def create_read_error_manifest(agent, stub_exe)
    manifest = [
      cron_manifest('first_entry', command: 'ls', user: username),
      file_manifest(stub_exe, ensure: :absent),
      cron_manifest('second_entry', command: 'ls', user: failed_username),
    ].join("\n\n")
    manifest_file = agent.tmpfile('crontab_overwrite_manifest')
    create_remote_file(agent, manifest_file, manifest)
    manifest_file
  end

  def execute_read_error_manifest(agent, stub_bin_dir, path_env_var, manifest_file)
    script_file = agent.tmpfile('apply_crontab_overwrite_manifest')
    script = <<-SCRIPT
  #!/usr/bin/env bash
  cd #{stub_bin_dir} && puppet apply #{manifest_file}
    SCRIPT
    create_remote_file(agent, script_file, script)
    on(agent, "chmod a+x #{script_file}")
    on(agent, "bash #{script_file}", environment: { PATH: "#{stub_bin_dir}:#{path_env_var}" })
  end

  def verify_unreadable_user_failed(puppet_result)
    step 'Verify that Puppet fails a Cron resource associated with an unreadable crontab file' do
      expect(puppet_result.stderr).to(match(%r{Cron.*second_entry}), 'Puppet does not fail a Cron resource associated with an unreadable crontab file')
    end
  end

  def verify_readable_user_succeeded(puppet_result)
    step 'Verify that Puppet does not fail a Cron resource associated with a readable crontab file' do
      expect(puppet_result.stderr).not_to(match(%r{Cron.*first_entry}), 'Puppet fails a Cron resource associated with a readable crontab file')
    end
    step 'Verify that Puppet successfully evaluates a Cron resource associated with a readable crontab file' do
      expect(puppet_result.stdout).to(match(%r{Cron.*first_entry}), 'Puppet fails to evaluate a Cron resource associated with a readable crontab file')
    end
  end

  def verify_readable_user_crontab(agent)
    step 'Verify that Puppet did update the readable crontab file with the Cron resource' do
      assert_matching_arrays(['* * * * * ls'], crontab_entries_of(agent, username), 'Puppet fails to update a readable crontab file with the specified Cron entry')
    end
  end
end
