# frozen_string_literal: true

require 'spec_helper_acceptance'

RSpec.context 'when Puppet cannot read a crontab file' do
  let(:username) { "pl#{rand(999_999).to_i}" }
  let(:crontab_contents) { '6 6 6 6 6 /usr/bin/true' }

  before(:each) do
    compatible_agents.each do |agent|
      step "Create the user on #{agent}" do
        user_present(agent, username)
      end

      step "Set the user's crontab on #{agent}" do
        run_cron_on(agent, :add, username, crontab_contents)
        assert_matching_arrays([crontab_contents], crontab_entries_of(agent, username), "Could not set the user's crontab for testing")
      end
    end
  end

  after(:each) do
    compatible_agents.each do |agent|
      step "Teardown -- Erase the user on #{agent}" do
        run_cron_on(agent, :remove, username)
        user_absent(agent, username)
      end
    end
  end

  compatible_agents.each do |agent|
    it "does not overwrite it on #{agent}" do
      expect { verify_crontab_is_preserved(agent) }.not_to raise_error
    end
  end

  def verify_crontab_is_preserved(agent)
    crontab_exe = find_crontab_executable(agent)
    stub_crontab_bin_dir, stub_crontab_exe = create_crontab_read_error_stub(agent)
    path_env_var = find_agent_path(agent)
    run_crontab_overwrite_scenario(agent, stub_crontab_bin_dir, stub_crontab_exe, crontab_exe, path_env_var)
    verify_crontab_contents(agent)
  end

  def find_crontab_executable(agent)
    executable = nil
    step 'Find the crontab executable' do
      executable = on(agent, 'which crontab').stdout.chomp
    end
    executable
  end

  def create_crontab_read_error_stub(agent)
    bin_dir = remote_tmpdir(agent, 'stub_crontab_bin_dir')
    on(agent, "chown #{username} #{bin_dir}")
    executable = "#{bin_dir}/crontab"
    script = <<-SCRIPT
  #!/usr/bin/env bash
  exit 1
    SCRIPT
    create_remote_file(agent, executable, script)
    on(agent, "chown #{username} #{executable}")
    on(agent, "chmod a+x #{executable}")
    [bin_dir, executable]
  end

  def find_agent_path(agent)
    path = nil
    step 'Get the value of the PATH environment variable' do
      path = on(agent, 'echo $PATH').stdout.chomp
    end
    path
  end

  def run_crontab_overwrite_scenario(agent, bin_dir, stub_exe, crontab_exe, path_env_var)
    step "(PUP-9217) Attempt to overwrite the user's crontab file" do
      manifest_file = create_overwrite_manifest(agent, stub_exe, crontab_exe)
      execute_overwrite_manifest(agent, bin_dir, path_env_var, manifest_file)
    end
  end

  def create_overwrite_manifest(agent, stub_exe, crontab_exe)
    # This reproduces the failed prefetch followed by writes to both entries.
    manifest = [
      cron_manifest('first_entry', command: 'ls', user: username),
      file_manifest(stub_exe, content: "#!/usr/bin/env bash\n#{crontab_exe} $@"),
      cron_manifest('second_entry', command: 'ls', user: username),
    ].join("\n\n")
    manifest_file = agent.tmpfile('crontab_overwrite_manifest')
    create_remote_file(agent, manifest_file, manifest)
    manifest_file
  end

  def execute_overwrite_manifest(agent, bin_dir, path_env_var, manifest_file)
    script_file = agent.tmpfile('apply_crontab_overwrite_manifest')
    script = <<-SCRIPT
  #!/usr/bin/env bash

  cd #{bin_dir} && puppet apply #{manifest_file}
    SCRIPT
    create_remote_file(agent, script_file, script)
    on(agent, "chmod a+x #{script_file}")
    on(agent, "bash #{script_file}", environment: { PATH: "#{bin_dir}:#{path_env_var}" })
  end

  def verify_crontab_contents(agent)
    step "(PUP-9217) Verify that Puppet does not overwrite the user's crontab file when it fails to read it" do
      assert_matching_arrays([crontab_contents], crontab_entries_of(agent, username), "Puppet overwrote the user's crontab file even though it failed to read it")
    end
  end
end
