# frozen_string_literal: true

require 'spec_helper'

describe Puppet::Type.type(:cron).provider(:crontab) do
  subject(:provider) do
    provider = Puppet::Type.type(:cron).provider(:crontab)
    provider.initvars
    provider
  end

  def crontab_text_parts(text)
    lines = text.lines
    [lines.first(4).all? { |line| line.match?(%r{^# }) }, lines.drop(4).join]
  end

  def normalized_record(record)
    fields = [:record_type, :command, :minute, :hour, :month, :monthday, :weekday, :environment, :line]
    fields.to_h { |field| [field, record.fetch(field, :absent)] }
  end

  context 'with the simple samples' do
    let(:fields) do
      {
        crontab: [:command, :minute, :hour, :month, :monthday, :weekday],
        environment: [:line],
        blank: [:line],
        comment: [:line],
      }
    end

    def normalized_sample_record(record)
      normalized_record(record).slice(*fields[record[:record_type]], :record_type)
    end

    ########################################################################
    # Simple input fixtures for testing.
    samples = YAML.load_file(my_fixture('single_line.yaml'))

    samples.each do |name, data|
      it "parses crontab line #{name} correctly" do
        expect(normalized_sample_record(provider.parse_line(data[:text]))).to eq(normalized_sample_record(data[:record]))
      end

      it "reconstructs the crontab line #{name} from the record" do
        expect(provider.to_line(data[:record])).to eq(data[:text])
      end
    end

    records = []
    text    = +''

    # Sorting is from the original, and avoids :empty being the last line,
    # since the provider will ignore that and cause this to fail.
    samples.sort_by { |x| x.first.to_s }.each do |_name, data|
      records << data[:record]
      text    << "#{data[:text]}\n"
    end

    it 'parses all sample records at once' do
      parsed = provider.parse(text).map { |record| normalized_sample_record(record) }
      expected = records.map { |record| normalized_sample_record(record) }
      expect(parsed).to eq(expected)
    end

    it 'reconstitutes the file from the records' do
      expect(crontab_text_parts(provider.to_file(records))).to eq([true, text])
    end

    context 'with multi-line crontabs' do
      tests = { simple: [:spaces_in_command_with_times],
                with_name: [:name, :spaces_in_command_with_times],
                with_env: [:environment, :spaces_in_command_with_times],
                with_multiple_envs: [:environment, :lowercase_environment, :spaces_in_command_with_times],
                with_name_and_env: [:name_with_spaces, :another_env, :spaces_in_command_with_times],
                with_name_and_multiple_envs: [:long_name, :another_env, :fourth_env, :spaces_in_command_with_times] }

      all_records = []
      all_text    = +''

      tests.each do |name, content|
        data    = content.map { |x| samples[x] || raise("missing sample data #{x}") }
        text    = "#{data.map { |x| x[:text] }.join("\n")}\n"
        records = data.map { |x| x[:record] }

        # Capture the whole thing for later, too...
        all_records += records
        all_text    += text

        it "regenerates the #{name.to_s.tr('_', ' ')} text from the record" do
          expect(crontab_text_parts(provider.to_file(records))).to eq([true, text])
        end

        it "parses the #{name.to_s.tr('_', ' ')} records from the text" do
          parsed = provider.parse(text).map { |record| normalized_sample_record(record) }
          expected = records.map { |record| normalized_sample_record(record) }
          expect(parsed).to eq(expected)
        end
      end

      it 'parses the whole set of records from the text' do
        parsed = provider.parse(all_text).map { |record| normalized_sample_record(record) }
        expected = all_records.map { |record| normalized_sample_record(record) }
        expect(parsed).to eq(expected)
      end

      it 'regenerates the whole text from the set of all records' do
        expect(crontab_text_parts(provider.to_file(all_records))).to eq([true, all_text])
      end
    end
  end

  context 'when receiving a vixie cron header from the cron interface' do
    it 'does not write that header back to disk' do
      vixie_header = File.read(my_fixture('vixie_header.txt'))
      vixie_records = provider.parse(vixie_header)
      expect(crontab_text_parts(provider.to_file(vixie_records))).to eq([true, ''])
    end
  end

  context 'when adding a cronjob with the same command as an existing job' do
    let(:resource) { Puppet::Type::Cron.new(name: 'test', user: 'root', command: '/bin/true') }
    let(:resources) { { 'test' => resource } }

    before :each do
      allow(File).to receive(:readable?).and_call_original
      allow(File).to receive(:readable?).with(provider.crontab_dir).and_return(false)
      allow(Puppet::Util::Execution).to receive(:execute)
        .and_return("# Puppet Name: existing\n0 0 * * * /bin/true\n")
    end

    it "does not base the new resource's provider on the existing record" do
      current_provider = resource.provider
      provider.prefetch(resources)
      expect(resource.provider).to eq(current_provider)
    end
  end

  context 'when prefetching an entry now managed for another user' do
    let(:resource) do
      s = instance_double(Puppet::Type.type(:cron))
      allow(s).to receive(:[]).with(:user).and_return 'root'
      allow(s).to receive(:[]).with(:target).and_return 'root'
      s
    end

    let(:record) { { name: 'test', user: 'nobody', command: '/bin/true', record_type: :crontab } }
    let(:resources) { { 'test' => resource } }

    it 'does not find the resource when looking up the on-disk record' do
      expect(provider.resource_for_record(record, resources)).to be_nil
    end
  end

  context 'when matching resources to existing crontab entries' do
    let(:first_resource) { Puppet::Type::Cron.new(name: :one, user: 'root', command: '/bin/true') }
    let(:second_resource) { Puppet::Type::Cron.new(name: :two, user: 'nobody', command: '/bin/false') }

    let(:resources) { { one: first_resource, two: second_resource } }

    describe 'when a record has a matching name and mismatching user (#2251)' do
      # Puppet::Resource objects have #should defined on them, so in these
      # examples we have to use the monkey patched `must` alias for the rspec
      # `should` method.

      it "doesn't match the record to the resource" do
        record = { name: :one, user: 'notroot', record_type: :crontab }
        expect(provider.resource_for_record(record, resources)).to be_nil
      end
    end

    describe 'when a record has a matching name and matching user' do
      it 'matches the record to the resource' do
        record = { name: :two, target: 'nobody', command: '/bin/false' }
        expect(provider.resource_for_record(record, resources)).to eq(second_resource)
      end
    end
  end

  describe '#enumerate_crontabs' do
    before(:each) do
      allow(File).to receive(:readable?).with(provider.crontab_dir).and_return(true)
      allow(File).to receive(:writable?).and_call_original
    end

    context 'when there is only a hidden file' do
      let(:file) { '.keep_cronbase-0' }

      before(:each) do
        path = File.join(provider.crontab_dir, file)
        allow(Dir).to receive(:foreach).with(provider.crontab_dir).and_yield(file)
        allow(File).to receive(:file?).with(path).and_return(true)
        allow(File).to receive(:writable?).with(path).and_return(true)
      end

      it 'ignores .keep_* files' do
        expect { |b| described_class.enumerate_crontabs(&b) }.not_to yield_control
      end
    end

    context 'when there are multiple files' do
      let(:files) { ['myuser', '.keep_cronbase-0'] }

      before(:each) do
        allow(Dir).to receive(:foreach).with(provider.crontab_dir).and_yield(files[0]).and_yield(files[1])

        files.each do |filename|
          path = File.join(provider.crontab_dir, filename)
          allow(File).to receive(:file?).with(path).and_return(true)
          allow(File).to receive(:writable?).with(path).and_return(true)
        end
      end

      it 'ignores .keep_* files' do
        expect { |b| described_class.enumerate_crontabs(&b) }.to yield_control.once
      end
    end
  end
end
