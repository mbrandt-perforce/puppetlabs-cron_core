# frozen_string_literal: true

require 'spec_helper'

describe Puppet::Type.type(:cron).provider(:crontab) do
  let :provider do
    described_class.new(command: '/bin/true')
  end

  describe 'when determining the correct filetype' do
    it 'uses the suntab filetype on Solaris' do
      allow(Facter).to receive(:value).with('os.family').and_return 'Solaris'
      expect(described_class.filetype).to eq(Puppet::Provider::Cron::FileType::FileTypeSuntab)
    end

    it 'uses the aixtab filetype on AIX' do
      allow(Facter).to receive(:value).with('os.family').and_return 'AIX'
      expect(described_class.filetype).to eq(Puppet::Provider::Cron::FileType::FileTypeAixtab)
    end

    it 'uses the crontab filetype on other platforms' do
      allow(Facter).to receive(:value).with('os.family').and_return 'Not a real operating system family'
      expect(described_class.filetype).to eq(Puppet::Provider::Cron::FileType::FileTypeCrontab)
    end
  end

  # I'd use expect(ENV).to receive(:[]).with('USER') but this does not work because
  # ENV["USER"] is evaluated at load time.
  describe 'when determining the default target' do
    it "uses the current user #{ENV.fetch('USER', nil)}", if: ENV.fetch('USER', nil) do
      expect(described_class.default_target).to eq(ENV.fetch('USER', nil))
    end

    it 'fallbacks to root', unless: ENV.fetch('USER', nil) do
      expect(described_class.default_target).to eq('root')
    end
  end

  describe '.targets', :aggregate_failures do
    let(:tabs) { [described_class.default_target] + ['foo', 'bar'] }

    before(:each) do
      allow(File).to receive_messages(readable?: true, file?: true, writable?: true)
    end

    it 'adds all crontabs as targets' do
      expect(Dir).to receive(:foreach).and_yield(tabs[0]).and_yield(tabs[1]).and_yield(tabs[2])
      expect(described_class.targets).to eq(tabs)
    end
  end

  describe 'when parsing a record', :aggregate_failures do
    it 'parses a comment' do
      expect(described_class.parse_line('# This is a test')).to eq(record_type: :comment,
                                                                   line: '# This is a test')
    end

    it 'gets the resource name of a PUPPET NAME comment' do
      expect(described_class.parse_line('# Puppet Name: My Fancy Cronjob')).to eq(record_type: :comment,
                                                                                  name: 'My Fancy Cronjob',
                                                                                  line: '# Puppet Name: My Fancy Cronjob')
    end

    it 'ignores blank lines' do
      expect(described_class.parse_line('')).to eq(record_type: :blank, line: '')
      expect(described_class.parse_line(' ')).to eq(record_type: :blank, line: ' ')
      expect(described_class.parse_line("\t")).to eq(record_type: :blank, line: "\t")
      expect(described_class.parse_line("  \t ")).to eq(record_type: :blank, line: "  \t ")
    end

    it 'extracts environment assignments' do
      # man 5 crontab: MAILTO="" with no value can be used to surpress sending
      # mails at all
      expect(described_class.parse_line('MAILTO=""')).to eq(record_type: :environment, line: 'MAILTO=""')
      expect(described_class.parse_line('FOO=BAR')).to eq(record_type: :environment, line: 'FOO=BAR')
      expect(described_class.parse_line('FOO_BAR=BAR')).to eq(record_type: :environment, line: 'FOO_BAR=BAR')
      expect(described_class.parse_line('SPACE = BAR')).to eq(record_type: :environment, line: 'SPACE = BAR')
    end

    {
      '* * * * * /bin/true' => {
        record_type: :crontab, hour: :absent, minute: :absent,
        month: :absent, weekday: :absent, monthday: :absent,
        special: :absent, command: '/bin/true'
      },
      '0,15,30,45 8-18,20-22 31 12 7 /bin/true' => {
        record_type: :crontab, minute: ['0', '15', '30', '45'],
        hour: ['8-18', '20-22'], monthday: ['31'], month: ['12'],
        weekday: ['7'], special: :absent, command: '/bin/true'
      },
      '0 22 * * 1-5   mail -s "It\'s 10pm" joe%Joe,%%Where are your kids?%' => {
        record_type: :crontab, minute: ['0'], hour: ['22'],
        monthday: :absent, month: :absent, weekday: ['1-5'],
        special: :absent,
        command: 'mail -s "It\'s 10pm" joe%Joe,%%Where are your kids?%'
      },
    }.each do |line, expected|
      it "extracts the cron entry from #{line}" do
        expect(described_class.parse_line(line)).to eq(expected)
      end
    end

    describe 'when supporting special strings' do
      ['reboot', 'yearly', 'anually', 'monthly', 'weekly', 'daily', 'midnight', 'hourly'].each do |special|
        it "supports @#{special}" do
          expect(described_class.parse_line("@#{special} /bin/true")).to eq(expected_special_record(special))
        end
      end
    end
  end

  def expected_special_record(special)
    { record_type: :crontab, hour: :absent, minute: :absent, month: :absent,
      weekday: :absent, monthday: :absent, special:, command: '/bin/true' }
  end

  describe '.instances' do
    def instance_parameters
      described_class.instances.map { |instance| parameters_for(instance) }
    end

    def parameters_for(instance)
      parameters = Puppet::Type.type(:cron).validproperties.to_h do |property|
        [property, instance.get(property)]
      end
      parameters.merge(name: instance.get(:name))
    end

    def parameters_match?(actual, expected)
      expected.all? do |field, value|
        value.is_a?(Regexp) ? actual[field].match?(value) : actual[field] == value
      end
    end

    let(:unmanaged_parameters) do
      [
        {
          name: %r{unmanaged:\$HOME/bin/daily.job_>>_\$HOME/tmp/out_2>&1-\d+},
          minute: ['5'], hour: ['0'], weekday: :absent, month: :absent,
          monthday: :absent, special: :absent,
          command: %r{\$HOME/bin/daily.job >> \$HOME/tmp/out 2>&1},
          ensure: :present, environment: [], user: :absent
        },
        {
          name: %r{unmanaged:\$HOME/bin/monthly-\d+},
          minute: ['15'], hour: ['14'], weekday: :absent, month: :absent,
          monthday: ['1'], special: :absent,
          command: %r{\$HOME/bin/monthly},
          ensure: :present, environment: [], user: :absent, target: 'foobar'
        },
      ]
    end

    before :each do
      allow(described_class).to receive(:targets).and_return ['foobar']
    end

    describe 'on linux', :aggregate_failures do
      let(:expected_managed_parameters) do
        [
          {
            name: 'real_job', minute: :absent, hour: :absent, weekday: :absent,
            month: :absent, monthday: :absent, special: :absent, command: '/bin/true',
            ensure: :present, environment: [], user: :absent, target: 'foobar'
          },
          {
            name: 'complex_job', minute: :absent, hour: :absent, weekday: :absent,
            month: :absent, monthday: :absent, special: 'reboot',
            command: '/bin/true >> /dev/null 2>&1', ensure: :present,
            environment: ['MAILTO=foo@example.com', 'SHELL=/bin/sh'],
            user: :absent, target: 'foobar'
          },
        ]
      end

      before(:each) do
        allow(Facter).to receive(:value).and_wrap_original do |original, fact|
          (fact == 'os.family') ? 'Linux' : original.call(fact)
        end
      end

      it 'contains no resources for a user who has no crontab' do
        allow(Puppet::Util).to receive(:uid).and_return(10)

        allow(Puppet::Util::Execution).to receive(:execute).with('crontab -u foobar -l', { failonfail: true, combine: true }).and_return('')
        expect(described_class.instances).to be_empty
      end

      it 'contains no resources for a user who is absent' do
        allow(Puppet::Util).to receive(:uid).and_return(nil)

        expect(described_class.instances).to be_empty
      end

      it 'is able to create records from not-managed records' do
        allow(described_class).to receive(:target_object).and_return File.new(my_fixture('simple'))
        expect(instance_parameters.zip(unmanaged_parameters)).to all(satisfy { |actual, expected| parameters_match?(actual, expected) })
      end

      it 'is able to parse puppet managed cronjobs' do
        allow(described_class).to receive(:target_object).and_return File.new(my_fixture('managed'))
        expect(instance_parameters).to eq(expected_managed_parameters)
      end
    end
  end

  describe '.match' do
    describe 'normal records' do
      let(:resource) do
        Puppet::Type.type(:cron).new(
          minute: ['0', '15', '30', '45'],
          hour: ['8-18', '20-22'],
          monthday: ['31'],
          month: ['12'],
          weekday: ['7'],
          name: 'basic',
          command: '/bin/true',
          target: 'root',
          provider:,
        )
      end
      let(:record) do
        {
          record_type: :crontab,
          minute: ['0', '15', '30', '45'],
          hour: ['8-18', '20-22'],
          monthday: ['31'],
          month: ['12'],
          weekday: ['7'],
          special: :absent,
          command: '/bin/true',
          on_disk: true,
          target: 'root',
        }
      end

      it 'matches when all fields are the same' do
        expect(described_class.match(record, resource[:name] => resource)).to eq(resource)
      end

      {
        minute: ['0', '15', '31', '45'],
        hour: ['8-18'],
        monthday: ['30', '31'],
        month: ['12', '23'],
        weekday: ['4'],
        command: '/bin/false',
        target: 'nobody',
      }.each_pair do |field, new_value|
        it "does not match a record when #{field} does not match" do
          record[field] = new_value
          expect(described_class.match(record, resource[:name] => resource)).to be_falsey
        end
      end
    end

    describe 'special records' do
      let(:resource_special) do
        Puppet::Type.type(:cron).new(
          special: 'reboot',
          name: 'special',
          command: '/bin/true',
          target: 'nobody',
        )
      end
      let(:record_special) do
        {
          record_type: :crontab,
          special: 'reboot',
          command: '/bin/true',
          on_disk: true,
          target: 'nobody',
        }
      end

      it 'matches when all fields are the same' do
        expect(described_class.match(record_special, resource_special[:name] => resource_special)).to eq(resource_special)
      end

      {
        special: 'monthly',
        command: '/bin/false',
        target: 'root',
      }.each_pair do |field, new_value|
        it "does not match a record when #{field} does not match" do
          record_special[field] = new_value
          expect(described_class.match(record_special, resource_special[:name] => resource_special)).to be_falsey
        end
      end
    end

    describe 'with a resource without a command' do
      let(:record) { { record_type: :crontab, command: '/bin/true' } }

      let(:resource_sparse) do
        Puppet::Type.type(:cron).new(
          minute: ['42'],
          target: 'root',
          name: 'sparse',
        )
      end

      it 'does not raise an error' do
        expect { described_class.match(record, resource_sparse[:name] => resource_sparse) }.not_to raise_error
      end
    end
  end
end
