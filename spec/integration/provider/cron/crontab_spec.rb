# frozen_string_literal: true

require 'spec_helper'
require 'puppet/file_bucket/dipper'
require 'puppet_spec/compiler'

describe Puppet::Type.type(:cron).provider(:crontab), unless: Puppet.features.microsoft_windows? do
  include PuppetSpec::Files
  include PuppetSpec::Compiler

  before :each do
    allow(Puppet::Type.type(:cron)).to receive_messages(defaultprovider: described_class)
    allow(described_class).to receive_messages(
      suitable?: true,
      filetype: Puppet::Util::FileType::FileTypeFlat,
      default_target: primary_crontab,
      header: "# HEADER: some simple\n# HEADER: header\n",
    )
    allow_any_instance_of(Puppet::FileBucket::Dipper).to receive_messages(backup: nil) # rubocop:disable RSpec/AnyInstance

    # I don't want to execute anything
    FileUtils.cp(my_fixture('crontab_user1'), primary_crontab)
    FileUtils.cp(my_fixture('crontab_user2'), secondary_crontab)
  end

  after :each do
    described_class.clear
  end

  let :primary_crontab do
    tmpfile('cron_integration_specs')
  end

  let :secondary_crontab do
    tmpfile('cron_integration_specs')
  end

  def expect_output(fixture_name)
    expect(File.read(primary_crontab)).to eq(File.read(my_fixture(fixture_name)))
  end

  def run_manifest_and_expect(manifest, fixture_name)
    apply_with_error_check(manifest)
    expect_output(fixture_name)
  end

  def expect_missing_command_error(manifest)
    apply_compiled_manifest(manifest) do |resource|
      if resource.ref == 'Cron[Entirely new resource]'
        expect(resource).to receive(:err).with(%r{no command})
      else
        expect(resource).not_to receive(:err)
      end
    end
  end

  def expect_moved_cron_inputs
    expect(File.read(primary_crontab)).to eq(File.read(my_fixture('moved_cronjob_input1')))
    expect(File.read(secondary_crontab)).to eq(File.read(my_fixture('moved_cronjob_input2')))
  end

  describe 'when managing a cron entry' do
    let(:manifests) do
      {
        purge: <<~PURGE,
          cron {
            'only managed entry':
              ensure      => 'present',
              command     => '/bin/true',
              target      => '#{primary_crontab}',
          }
          resources { 'cron': purge => 'true' }
        PURGE
        absent: <<~ABSENT,
          cron {
            'no_such_entry':
              ensure => 'absent',
              target => '#{primary_crontab}',
          }
        ABSENT
        remove_named: <<~REMOVE_NAMED,
          cron {
            'My daily failure':
              ensure => 'absent',
              target => '#{primary_crontab}',
          }
        REMOVE_NAMED
        remove_matching: <<~REMOVE_MATCHING,
          cron {
            'no_such_named_resource_in_crontab':
              ensure   => absent,
              minute   => [ '17-19', '22' ],
              hour     => [ '0-23/2' ],
              weekday  => 'Tue',
              command  => '/bin/unnamed_regular_command',
              target   => '#{primary_crontab}',
          }
        REMOVE_MATCHING
        present_without_command: <<~PRESENT_WITHOUT_COMMAND,
          cron {
            'My daily failure':
              special => 'daily',
              target  => '#{primary_crontab}',
          }
        PRESENT_WITHOUT_COMMAND
        new_without_command: <<~NEW_WITHOUT_COMMAND,
          cron {
            'Entirely new resource':
              special => 'daily',
              target  => '#{primary_crontab}',
          }
        NEW_WITHOUT_COMMAND
        present: <<~PRESENT,
          cron {
            'My daily failure':
              special => 'daily',
              command => '/bin/false',
              target  => '#{primary_crontab}',
          }
        PRESENT
        target_without_user: <<~TARGET_WITHOUT_USER,
          cron {
            'My weekly failure':
              special => 'weekly',
              command => '/bin/false',
              target  => '#{primary_crontab}',
          }
        TARGET_WITHOUT_USER
        matching_present: <<~MATCHING_PRESENT,
          cron {
            'no_such_named_resource_in_crontab':
              ensure   => present,
              minute   => [ '17-19', '22' ],
              hour     => [ '0-23/2' ],
              command  => '/bin/unnamed_regular_command',
              target   => '#{primary_crontab}',
          }
        MATCHING_PRESENT
        new_normal: <<~NEW_NORMAL,
          cron {
            'new entry':
              ensure      => present,
              minute      => '12',
              weekday     => 'Tue',
              command     => '/bin/new',
              environment => [
                'MAILTO=""',
                'SHELL=/bin/bash'
              ],
              target      => '#{primary_crontab}',
          }
        NEW_NORMAL
        new_special: <<~NEW_SPECIAL,
          cron {
            'new special entry':
              ensure      => present,
              special     => 'reboot',
              command     => 'echo "Booted" 1>&2',
              environment => 'MAILTO=bob@company.com',
              target      => '#{primary_crontab}',
          }
        NEW_SPECIAL
        modified: <<~MODIFIED,
          cron {
            'Monthly job':
              ensure      => present,
              special     => 'monthly',
              #minute => ['22'],
              command     => '/usr/bin/monthly',
              environment => [],
              target      => '#{primary_crontab}',
          }
        MODIFIED
        unspecialized: <<~UNSPECIALIZED,
          cron {
            'My daily failure':
              special     => 'absent',
              command     => '/bin/false',
              target      => '#{primary_crontab}',
          }
        UNSPECIALIZED
        moved_entries: <<~MOVED_ENTRIES,
          cron {
            'foo':
              ensure => absent,
              target => '#{primary_crontab}';
            'My daily failure':
              special      => 'daily',
              command      => "/bin/false",
              target       => '#{secondary_crontab}',
          }
        MOVED_ENTRIES
      }
    end

    it 'is able to purge unmanaged entries' do
      expect { run_manifest_and_expect(manifests[:purge], 'purged') }.not_to raise_error
    end

    describe 'with ensure absent' do
      it 'does nothing if entry already absent' do
        expect { run_manifest_and_expect(manifests[:absent], 'crontab_user1') }.not_to raise_error
      end

      it 'removes the resource from crontab if present' do
        expect { run_manifest_and_expect(manifests[:remove_named], 'remove_named_resource') }.not_to raise_error
      end

      it 'removes a matching cronentry if present' do
        expect { run_manifest_and_expect(manifests[:remove_matching], 'remove_unnamed_resource') }.not_to raise_error
      end
    end

    describe 'with ensure present' do
      it 'works if a commandless resource is already present' do
        expect { run_manifest_and_expect(manifests[:present_without_command], 'crontab_user1') }.not_to raise_error
      end

      it 'fails if a commandless resource needs creating' do
        expect { expect_missing_command_error(manifests[:new_without_command]) }.not_to raise_error
      end

      it 'does nothing if entry already present' do
        expect { run_manifest_and_expect(manifests[:present], 'crontab_user1') }.not_to raise_error
      end

      it "works correctly when managing 'target' but not 'user'" do
        expect { run_manifest_and_expect(manifests[:target_without_user], 'crontab_user3') }.not_to raise_error
      end

      it 'does nothing if a matching entry already present' do
        expect { run_manifest_and_expect(manifests[:matching_present], 'crontab_user1') }.not_to raise_error
      end

      it 'adds a new normal entry if currently absent' do
        expect { run_manifest_and_expect(manifests[:new_normal], 'create_normal_entry') }.not_to raise_error
      end

      it 'adds a new special entry if currently absent' do
        expect { run_manifest_and_expect(manifests[:new_special], 'create_special_entry') }.not_to raise_error
      end

      it 'changes existing entry if out of sync' do
        expect { run_manifest_and_expect(manifests[:modified], 'modify_entry') }.not_to raise_error
      end

      it 'changes a special schedule to numeric if requested' do
        expect { run_manifest_and_expect(manifests[:unspecialized], 'unspecialized') }.not_to raise_error
      end

      it 'does not try to move an entry from one file to another' do
        expect {
          apply_with_error_check(manifests[:moved_entries])
          expect_moved_cron_inputs
        }.not_to raise_error
      end
    end
  end
end
