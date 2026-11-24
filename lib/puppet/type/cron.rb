# frozen_string_literal: true

require 'etc'
require 'facter'
require 'puppet/util/filetype'

# Shared validation and value handling for cron schedule properties.
class CronParam < Puppet::Property
  class << self
    attr_accessor :boundaries, :default
  end

  # We have to override the parent method, because we consume the entire
  # "should" array
  def insync?(current)
    is_to_s(current) == should_to_s
  end

  # A method used to do parameter input handling.  Converts integers
  # in string form to actual integers, and returns the value if it's
  # an integer or false if it's just a normal string.
  def numfix(num)
    return false unless num.is_a?(Integer) || num.is_a?(String)

    # Ensure num is a string before checking against regex & allow leading zeros
    ((num.is_a?(String) && %r{^\d+$}.match?(num)) || Integer(num, exception: false)) ? num : false
  end

  # Verify that a number is within the specified limits.  Return the
  # number if it is, or false if it is not.
  def limitcheck(num, lower, upper)
    (num.to_i >= lower && num.to_i <= upper) && num
  end

  # Verify that a value falls within the specified array.  Does case
  # insensitive matching, and supports matching either the entire word
  # or the first three letters of the word.
  def alphacheck(value, ary)
    return false unless value.is_a?(String)

    tmp = value.downcase

    # If they specified a shortened version of the name, then see
    # if we can lengthen it (e.g., mon => monday).
    if tmp.length == 3
      ary.each_with_index do |name, index|
        return index if tmp.casecmp(name[0..2]).zero?
      end
    elsif ary.include?(tmp)
      return ary.index(tmp)
    end

    false
  end

  def should_to_s(value = @should)
    if value
      value = value[0] if value.is_a?(Array) && (name == :command || value[0].is_a?(Symbol))
      super
    else
      nil
    end
  end

  def is_to_s(value = @is) # rubocop: disable Naming/PredicateName
    if value
      value = value[0] if value.is_a?(Array) && (name == :command || value[0].is_a?(Symbol))
      super
    else
      nil
    end
  end

  def should
    if @should && @should[0] == :absent
      :absent
    else
      @should
    end
  end

  def should=(ary)
    super
    @should.flatten!
  end

  # The method that does all of the actual parameter value
  # checking; called by all of the +param<name>=+ methods.
  # Requires the value, type, and bounds, and optionally supports
  # a boolean of whether to do alpha checking, and if so requires
  # the ary against which to do the checking.
  munge do |value|
    # Support 'absent' as a value, so that they can remove
    # a value
    return :absent if ['absent', :absent].include? value

    # Allow step syntax
    return value if %r{^\*/[0-9]+$}.match?(value.to_s)

    # Allow ranges
    return value if %r{^[0-9]+-[0-9]+$}.match?(value.to_s)

    # Allow ranges with step
    return value if %r{^[0-9]+-[0-9]+/[0-9]+$}.match?(value.to_s)

    return :absent if value == '*'

    return value unless self.class.boundaries

    lower, upper = self.class.boundaries
    retval = nil
    num = numfix(value)
    if num
      retval = limitcheck(num, lower, upper)
    elsif respond_to?(:alpha)
      # If it has an alpha method defined, then we check
      # to see if our value is in that list and if so we turn
      # it into a number
      retval = alphacheck(value, alpha)
    end

    raise _('%{value} is not a valid %{name}') % { value:, name: self.class.name } unless retval
    return retval.to_s if retval
  end
end

module CronTypeDocumentation
  TEXT = <<-CRON_TYPE_DOCUMENTATION
    @summary Installs and manages cron jobs.

    Every cron resource created by Puppet requires a command and at least one
    periodic attribute (hour, minute, month, monthday, weekday, or special). While
    the name of the cron job is not part of the actual job, the name is stored in a
    comment beginning with `# Puppet Name: `. These comments are used to match
    crontab entries created by Puppet with cron resources.

    If an existing crontab entry happens to match the scheduling and command of a
    cron resource that has never been synced, Puppet defers to the existing
    crontab entry and does not create a new entry tagged with the `# Puppet Name: `
    comment.

    @example

        cron { 'logrotate':
          command => '/usr/sbin/logrotate',
          user    => 'root',
          hour    => 2,
          minute  => 0,
        }

    @example Note that all periodic attributes can be specified as an array of values:

        cron { 'logrotate':
          command => '/usr/sbin/logrotate',
          user    => 'root',
          hour    => [2, 4],
        }

    @example ...or using ranges or the step syntax `*/2` (although there's no guarantee that your `cron` daemon supports these):

        cron { 'logrotate':
          command => '/usr/sbin/logrotate',
          user    => 'root',
          hour    => ['2-4'],
          minute  => '*/10',
        }

    **Important:** _The Cron type will not reset parameters that are
    removed from a manifest_. For example, removing a `minute => 10` parameter
    will not reset the minute component of the associated cronjob to `*`.
    These changes must be expressed by setting the parameter to
    `minute => absent` because Puppet only manages parameters that are out of
    sync with manifest entries.

    **Autorequires:** If Puppet is managing the user account specified by the
    `user` property of a cron resource, then the cron resource will autorequire
    that user.
  CRON_TYPE_DOCUMENTATION
end

# Install command and special schedule property behavior.
module CronTypeMainProperties
  COMMAND_DESCRIPTION = "The command to execute in the cron job.  The environment
      provided to the command varies by local system rules, and it is
      best to always provide a fully qualified command.  The user's
      profile is not sourced when the command is run, so if the
      user's environment is desired it should be sourced manually.

      All cron parameters support `absent` as a value; this will
      remove any existing values for that field."
  SPECIAL_DESCRIPTION = "A special value such as 'reboot' or 'annually'.
       Only available on supported systems such as Vixie Cron.
       Overrides more specific time of day/week settings.
       Set to 'absent' to make puppet revert to a plain numeric schedule."

  def self.install_command(property)
    property.desc(COMMAND_DESCRIPTION)
    property.include(CronCommandPropertyMethods)
  end

  def self.install_special(property)
    property.desc(SPECIAL_DESCRIPTION)
    property.validate { |value| CronTypeMainProperties.validate_special(value) }
    property.include(CronSpecialPropertyMethods)
  end

  def self.validate_special(value)
    specials = ['reboot', 'yearly', 'annually', 'monthly', 'weekly', 'daily', 'midnight', 'hourly', 'absent', :absent]
    return if specials.include?(value)

    raise ArgumentError, _('Invalid special schedule %{value}') % { value: value.inspect }
  end
end

# Instance methods for cron command properties.
module CronCommandPropertyMethods
  def retrieve
    return_value = super
    return_value = return_value[0] if return_value.is_a?(Array)
    return_value
  end

  def should
    return unless @should

    @should.is_a?(Array) ? @should[0] : devfail('command is not an array')
  end

  def munge(value)
    value.strip
  end
end

# Instance methods for special schedule properties.
module CronSpecialPropertyMethods
  def specials
    ['reboot', 'yearly', 'annually', 'monthly', 'weekly', 'daily', 'midnight', 'hourly', 'absent'] + [:absent]
  end

  def munge(value)
    return :absent if ['absent', :absent].include? value

    value
  end
end

# Install cron schedule field properties.
module CronTypeScheduleProperties
  WEEKDAY_DESCRIPTION = "The weekday on which to run the command. Optional; if specified,
      must be either:

      -   A number between 0 and 7, inclusive, with 0 or 7 being Sunday
      -   The name of the day, such as 'Tuesday'.

      Day ranges can only be numeric; e.g. '1-5' for weekdays, but not 'Mon-Fri'."
  MONTH_DESCRIPTION = "The month of the year. Optional; if specified,
      must be either:

      -   A number between 1 and 12, inclusive, with 1 being January
      -   The name of the month, such as 'December'."

  def self.install(type)
    install_numeric(type, :minute, [0, 59], "The minute at which to run the cron job.\n      Optional; if specified, must be between 0 and 59, inclusive.")
    install_numeric(type, :hour, [0, 23], "The hour at which to run the cron job. Optional;\n      if specified, must be between 0 and 23, inclusive.")
    install_weekday(type)
    install_month(type)
    install_numeric(type, :monthday, [1, 31], "The day of the month on which to run the\n      command.  Optional; if specified, must be between 1 and 31.")
  end

  def self.install_numeric(type, name, boundaries, description)
    type.newproperty(name, parent: CronParam) do
      self.boundaries = boundaries
      desc description
    end
  end

  def self.install_weekday(type)
    type.newproperty(:weekday, parent: CronParam) do
      self.boundaries = [0, 7]
      desc CronTypeScheduleProperties::WEEKDAY_DESCRIPTION
      include CronWeekdayPropertyMethods
    end
  end

  def self.install_month(type)
    type.newproperty(:month, parent: CronParam) do
      self.boundaries = [1, 12]
      desc CronTypeScheduleProperties::MONTH_DESCRIPTION
      include CronMonthPropertyMethods
    end
  end
end

# Weekday name mapping for the cron weekday property.
module CronWeekdayPropertyMethods
  def alpha
    ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday']
  end
end

# Month name mapping for the cron month property.
module CronMonthPropertyMethods
  def alpha
    # A placeholder preserves crontab's one-based month indices.
    ['___placeholder', 'january', 'february', 'march', 'april', 'may', 'june',
     'july', 'august', 'september', 'october', 'november', 'december']
  end
end

# Install environment, name, and owner properties.
module CronTypeGeneralProperties
  ENVIRONMENT_DESCRIPTION = "Any environment settings associated with this cron job.  They
      will be stored between the header and the job in the crontab.  There
      can be no guarantees that other, earlier settings will not also
      affect a given cron job.


      Also, Puppet cannot automatically determine whether an existing,
      unmanaged environment setting is associated with a given cron
      job.  If you already have cron jobs with environment settings,
      then Puppet will keep those settings in the same place in the file,
      but will not associate them with a specific job.

      Settings should be specified exactly as they should appear in
      the crontab, like `PATH=/bin:/usr/bin:/usr/sbin`."
  NAME_DESCRIPTION = "The symbolic name of the cron job.  This name
      is used for human reference only and is generated automatically
      for cron jobs found on the system.  This generally won't
      matter, as Puppet will do its best to match existing cron jobs
      against specified jobs (and Puppet adds a comment to cron jobs it adds),
      but it is at least possible that converting from unmanaged jobs to
      managed jobs might require manual intervention."
  USER_DESCRIPTION = "The user who owns the cron job.  This user must
      be allowed to run cron jobs, which is not currently checked by
      Puppet.

      This property defaults to the user running Puppet or `root`.

      The default crontab provider executes the system `crontab` using
      the user account specified by this property."
  TARGET_DESCRIPTION = "The name of the crontab file in which the cron job should be stored.

      This property defaults to the value of the `user` property if set, the
      user running Puppet or `root`.

      For the default crontab provider, this property is functionally
      equivalent to the `user` property and should be avoided. In particular,
      setting both `user` and `target` to different values will result in
      undefined behavior."

  def self.install(type)
    type.newproperty(:environment) { CronTypeGeneralProperties.install_environment(self) }
    type.newparam(:name) do
      desc CronTypeGeneralProperties::NAME_DESCRIPTION
      isnamevar
    end
    install_user(type)
    install_target(type)
  end

  def self.install_environment(property)
    property.desc(ENVIRONMENT_DESCRIPTION)
    property.validate { |value| CronTypeGeneralProperties.validate_environment(value) }
    property.include(CronEnvironmentPropertyMethods)
  end

  def self.validate_environment(value)
    valid_string = value.is_a?(String) && value =~ %r{^\s*(\w+)\s*=\s*(.*)\s*$}
    return if valid_string || value == :absent || value == 'absent'

    raise ArgumentError, _('Invalid environment setting %{value}') % { value: value.inspect }
  end

  def self.install_user(type)
    type.newproperty(:user) do
      desc CronTypeGeneralProperties::USER_DESCRIPTION
      defaultto { CronTypeGeneralProperties.user_default(self) }
    end
  end

  def self.install_target(type)
    type.newproperty(:target) do
      desc CronTypeGeneralProperties::TARGET_DESCRIPTION
      defaultto { CronTypeGeneralProperties.target_default(self) }
    end
  end

  def self.current_user
    struct = Etc.getpwuid(Process.uid)
    (struct.respond_to?(:name) && struct.name) || 'root'
  end

  def self.user_default(property)
    return if property.provider.is_a?(property.resource.class.provider(:crontab))

    current_user
  end

  def self.target_default(property)
    if property.provider.is_a?(property.resource.class.provider(:crontab))
      property.resource.should(:user) || current_user
    elsif property.provider.class.ancestors.include?(Puppet::Provider::ParsedFile)
      property.provider.class.default_target
    end
  end
end

# Environment property comparison and accessors.
module CronEnvironmentPropertyMethods
  def insync?(current)
    current.is_a?(Array) ? current.sort == @should.sort : current == @should
  end

  attr_reader :should

  def should_to_s(newvalue = @should)
    return nil unless newvalue

    newvalue.join(',')
  end
end

# Validate mutually exclusive cron schedule properties.
module CronTypeValidation
  def self.validate(resource)
    return true unless resource[:special]
    return true if resource[:special] == :absent

    [:minute, :hour, :weekday, :monthday, :month].each do |field|
      next unless resource[field]
      next if resource[field] == :absent

      message = _('%{cron} cannot specify both a special schedule and a value for %{field}') % ({ cron: resource.ref, field: })
      raise ArgumentError, message
    end
  end
end

# Instance methods shared by cron resources.
module CronTypeInstanceMethods
  attr_accessor :uid

  def purging
    self[:target] = provider.target
    self[:user] = provider.target
    super
  end

  def value(name)
    name = name.to_sym
    obj = @parameters[name]
    ret = obj&.should || obj&.retrieve
    ret = nil if ret == :absent
    ret = '*' if !ret && ![:command, :special].include?(name)
    ret
  end
end

# Register properties and behavior for the cron resource type.
module CronTypeDefinition
  def self.install(type)
    type.instance_variable_set(:@doc, CronTypeDocumentation::TEXT)
    type.ensurable
    type.newproperty(:command, parent: CronParam) { CronTypeMainProperties.install_command(self) }
    type.newproperty(:special) { CronTypeMainProperties.install_special(self) }
    CronTypeScheduleProperties.install(type)
    CronTypeGeneralProperties.install(type)
    type.autorequire(:user) { self[:user] }
    type.validate { CronTypeValidation.validate(self) }
    type.include(CronTypeInstanceMethods)
  end
end

Puppet::Type.newtype(:cron) do
  CronTypeDefinition.install(self)
end
