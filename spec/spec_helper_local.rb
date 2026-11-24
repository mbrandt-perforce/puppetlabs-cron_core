# frozen_string_literal: true

dir = __dir__
$LOAD_PATH.unshift File.join(dir, 'lib')

# Container for various Puppet-specific RSpec helpers.
module PuppetSpec
end

require 'puppet_spec/files'

RSpec.configure do |config|
  config.before :each do |_test|
    base = PuppetSpec::Files.tmpdir('tmp_settings')
    Puppet[:vardir] = File.join(base, 'var')

    FileUtils.mkdir_p Puppet[:statedir]
  end
end
