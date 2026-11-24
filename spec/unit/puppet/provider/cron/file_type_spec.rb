# frozen_string_literal: true

require 'spec_helper'
require 'puppet/provider/cron/filetype'

describe Puppet::Provider::Cron::FileType do
  shared_examples_for 'crontab provider' do
    let(:cron) { type.new('no_such_user') }

    def crontab
      File.read(my_fixture(crontab_output))
    end

    def options
      { failonfail: true, combine: true }
    end

    def uid
      'no_such_user'
    end

    def managedtab
      File.read(my_fixture('managed_output'))
    end

    def user_options
      options.merge(uid:)
    end

    it 'exists' do
      expect(type).not_to be_nil
    end

    # make Puppet::Util::SUIDManager return something deterministic, not the
    # uid of the user running the tests, except where overridden below.
    before :each do
      allow(Puppet::Util::SUIDManager).to receive(:uid).and_return 1234
    end

    describe '#read', :aggregate_failures do
      before(:each) do
        allow(Puppet::Util).to receive(:uid).with(uid).and_return 9000
      end

      it 'runs crontab -l as the target user' do
        allow(Puppet::Util::Execution).to receive(:execute).with(['crontab', '-l'], user_options).and_return(Puppet::Util::Execution::ProcessOutput.new(crontab, 0))
        expect(cron.read).to eq(crontab)
      end

      it 'returns a String' do
        allow(Puppet::Util::Execution).to receive(:execute).with(['crontab', '-l'], user_options).and_return(Puppet::Util::Execution::ProcessOutput.new(managedtab, 0))
        expect(cron.read).to be_an_instance_of(String)
      end

      it 'does not switch user if current user is the target user' do
        allow(Puppet::Util).to receive(:uid).with(uid).and_return 9000
        allow(Puppet::Util::SUIDManager).to receive(:uid).and_return 9000
        allow(Puppet::Util::Execution).to receive(:execute).with(['crontab', '-l'], options).and_return(Puppet::Util::Execution::ProcessOutput.new(crontab, 0))
        expect(cron.read).to eq(crontab)
      end

      it 'treats an absent crontab as empty' do
        allow(Puppet::Util::Execution).to receive(:execute).with(['crontab', '-l'], user_options).and_raise(Puppet::ExecutionFailure, absent_crontab)
        expect(cron.read).to eq('')
      end

      it "treats a nonexistent user's crontab as empty" do
        allow(Puppet::Util).to receive(:uid).with(uid).and_return nil

        expect(cron.read).to eq('')
      end

      it 'returns empty if the user is not authorized to use cron' do
        allow(Puppet::Util::Execution).to receive(:execute).with(['crontab', '-l'], user_options).and_raise(Puppet::ExecutionFailure, unauthorized_crontab)
        expect(cron.read).to eq('')
      end
    end

    describe '#remove', :aggregate_failures do
      it 'runs crontab -r as the target user' do
        expect(Puppet::Util::Execution).to receive(:execute).with(['crontab', '-r'], user_options)
        cron.remove
      end

      it 'does not switch user if current user is the target user' do
        allow(Puppet::Util).to receive(:uid).with(uid).and_return 9000
        allow(Puppet::Util::SUIDManager).to receive(:uid).and_return 9000
        expect(Puppet::Util::Execution).to receive(:execute).with(['crontab', '-r'], options)
        cron.remove
      end
    end

    describe '#write', :aggregate_failures do
      let!(:tmp_cron) { Tempfile.new('puppet_crontab_spec') }
      let!(:tmp_cron_path) { tmp_cron.path }

      before :each do
        allow(Puppet::Util).to receive(:uid).with(uid).and_return 9000
        allow(Tempfile).to receive(:new).with("puppet_#{type.name}", encoding: Encoding.default_external).and_return tmp_cron
      end

      after :each do
        allow(File).to receive(:chown).and_call_original
      end

      it 'runs crontab as the target user on a temporary file' do
        expect(File).to receive(:chown).with(9000, nil, tmp_cron_path)
        expect(Puppet::Util::Execution).to receive(:execute).with(['crontab', tmp_cron_path], user_options)
        expect(tmp_cron).to receive(:print).with("foo\n")
        write_crontab
      end

      it 'does not switch user if current user is the target user' do
        allow(Puppet::Util::SUIDManager).to receive(:uid).and_return 9000
        expect(File).to receive(:chown).with(9000, nil, tmp_cron_path)
        expect(Puppet::Util::Execution).to receive(:execute).with(['crontab', tmp_cron_path], options)
        expect(tmp_cron).to receive(:print).with("foo\n")
        write_crontab
      end
    end

    def expect_tmp_cron_removed
      expect(Puppet::FileSystem).not_to exist(tmp_cron_path)
    end

    def write_crontab
      cron.write "foo\n"
      expect_tmp_cron_removed
    end
  end

  describe 'the suntab filetype', unless: Puppet::Util::Platform.windows? do
    def type
      described_class.filetype(:suntab)
    end

    def crontab_output
      'suntab_output'
    end

    # possible crontab output was taken from here:
    # https://docs.oracle.com/cd/E19082-01/819-2380/sysrescron-60/index.html
    let(:absent_crontab) do
      'crontab: can\'t open your crontab file'
    end
    let(:unauthorized_crontab) do
      'crontab: you are not authorized to use cron. Sorry.'
    end

    it_behaves_like 'crontab provider'
  end

  describe 'the aixtab filetype', unless: Puppet::Util::Platform.windows? do
    def type
      described_class.filetype(:aixtab)
    end

    def crontab_output
      'aixtab_output'
    end

    let(:absent_crontab) do
      '0481-103 Cannot open a file in the /var/spool/cron/crontabs directory.'
    end
    let(:unauthorized_crontab) do
      '0481-109 You are not authorized to use the cron command.'
    end

    it_behaves_like 'crontab provider'
  end
end
