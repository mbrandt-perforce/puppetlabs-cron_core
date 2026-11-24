# frozen_string_literal: true

require 'puppet/util/filetype'

class Puppet::Provider::Cron
  # Shared read handling for the platform-specific cron file types.
  module CronReadMethods
    def read
      return '' unless existing_user?

      Puppet::Util::Execution.execute(read_command, read_options).to_s
    rescue StandardError => e
      return '' if empty_crontab_error?(e)
      return unauthorized_crontab if unauthorized_crontab_error?(e)

      raise Puppet::Util::FileType::FileReadError, read_error_message(e), e.backtrace
    end

    private

    def existing_user?
      return true if Puppet::Util.uid(@path)

      Puppet.debug _('The %{path} user does not exist. Treating their crontab file as empty in case Puppet creates them in the middle of the run.') % { path: @path }
      false
    end

    def unauthorized_crontab
      message = _('The %{path} user is not authorized to use cron. ' \
                  'Their crontab file is treated as empty in case Puppet authorizes them in the middle of the run ' \
                  '(by, for example, modifying the cron.deny or cron.allow files).') % { path: @path }
      Puppet.debug message
      ''
    end

    def read_error_message(error)
      _('Could not read crontab for %{path}: %{detail}') % ({ path: @path, detail: error })
    end
  end

  # Temporary-file writes shared by SunOS and AIX.
  module CronTempfileWriteMethods
    def write(text)
      output_file = Tempfile.new(tempfile_prefix, encoding: Encoding.default_external)
      begin
        write_tempfile(output_file, text)
      ensure
        output_file.close
        output_file.unlink
      end
    end

    private

    def write_tempfile(output_file, text)
      output_file.print text
      output_file.close
      File.chown(Puppet::Util.uid(@path), nil, output_file.path)
      Puppet::Util::Execution.execute(['crontab', output_file.path], cronargs).to_s
    rescue StandardError => e
      message = _('Could not write crontab for %{path}: %{detail}') % ({ path: @path, detail: e })
      raise Puppet::Util::FileType::FileReadError, message, e.backtrace
    end
  end

  # Linux crontab implementation.
  module LinuxCronFileType
    include CronReadMethods

    def initialize(user)
      self.path = user
    end

    def path=(user)
      @uid = Puppet::Util.uid(user)
      @path = user
    rescue Puppet::Error => e
      message = _('Could not retrieve user %{user}: %{detail}') % ({ user:, detail: e })
      raise Puppet::Util::FileType::FileReadError, message, e.backtrace
    end

    def read_command
      "#{cmdbase} -l"
    end

    def read_options
      { failonfail: true, combine: true }
    end

    def empty_crontab_error?(error)
      error.to_s.include?('no crontab for')
    end

    def unauthorized_crontab_error?(error)
      error.to_s.include?('are not allowed to')
    end

    def remove
      cmd = "#{cmdbase} -r"
      cmd = "/bin/echo yes | #{cmd}" if ['Darwin', 'FreeBSD', 'DragonFly'].include?(Facter.value('os.name'))
      Puppet::Util::Execution.execute(cmd, failonfail: true, combine: true).to_s
    end

    def write(text)
      ensure_user_exists
      IO.popen("#{cmdbase} -", 'w', encoding: Encoding.default_external) { |p| p.print text }
    end

    private

    def ensure_user_exists
      return if Puppet::Util.uid(@path)

      raise Puppet::Error, _("Cannot write the %{path} user's crontab: The user does not exist") % { path: @path }
    end

    # Only add the -u flag when the @path is different. Fedora apparently
    # does not think I should be allowed to set the @path to my own user name.
    def cmdbase
      return 'crontab' if @uid == Puppet::Util::SUIDManager.uid || Facter.value('os.name') == 'HP-UX'

      "crontab -u #{@path}"
    end
  end

  # SunOS crontab implementation.
  module SunCronFileType
    include CronReadMethods
    include CronTempfileWriteMethods

    def read_command
      ['crontab', '-l']
    end

    def read_options
      cronargs
    end

    def empty_crontab_error?(error)
      error.to_s.include?("can't open your crontab")
    end

    def unauthorized_crontab_error?(error)
      error.to_s.include?('you are not authorized to use cron')
    end

    def remove
      Puppet::Util::Execution.execute(['crontab', '-r'], cronargs).to_s
    rescue StandardError => e
      message = _('Could not remove crontab for %{path}: %{detail}') % ({ path: @path, detail: e })
      raise Puppet::Util::FileType::FileReadError, message, e.backtrace
    end

    private

    def tempfile_prefix
      'puppet_suntab'
    end
  end

  # AIX crontab implementation.
  module AixCronFileType
    include CronReadMethods
    include CronTempfileWriteMethods

    def read_command
      ['crontab', '-l']
    end

    def read_options
      cronargs
    end

    def empty_crontab_error?(error)
      %r{open.*in.*directory}.match?(error.to_s)
    end

    def unauthorized_crontab_error?(error)
      %r{not.*authorized.*cron}.match?(error.to_s)
    end

    def remove
      Puppet::Util::Execution.execute(['crontab', '-r'], cronargs).to_s
    rescue StandardError => e
      message = _('Could not remove crontab for %{path}: %{detail}') % ({ path: @path, detail: e })
      raise Puppet::Util::FileType::FileReadError, message, e.backtrace
    end

    private

    def tempfile_prefix
      'puppet_aixtab'
    end
  end

  # This class defines the crontab filetypes
  class FileType < Puppet::Util::FileType
    class << self
      define_method(:base_newfiletype, instance_method(:newfiletype))

      # Puppet::Util::FileType.newfiletype will raise an exception if
      # an already-defined filetype is re-defined. Unfortunately, there's
      # a chance that this file could be loaded multiple times by Puppet's
      # autoloader meaning that, without this wrapper, the crontab filetypes
      # would be re-defined, causing Puppet to raise an exception.
      def newfiletype(name, &)
        return if @filetypes&.key?(name)

        base_newfiletype(name, &)
      end
    end

    # Handle Linux-style cron tabs.
    #
    # TODO: We can possibly eliminate the "-u <username>" option in cmdbase
    # by just running crontab under <username>'s uid (like we do for suntab
    # and aixtab). It may be worth investigating this alternative
    # implementation in the future. This way, we can refactor all three of
    # our cron file types into a common crontab file type.
    newfiletype(:crontab) do
      include Puppet::Provider::Cron::LinuxCronFileType
    end

    # SunOS has completely different cron commands; this class implements
    # its versions.
    newfiletype(:suntab) do
      include Puppet::Provider::Cron::SunCronFileType
    end

    #  Support for AIX crontab with output different than suntab's crontab command.
    newfiletype(:aixtab) do
      include Puppet::Provider::Cron::AixCronFileType
    end
  end
end
