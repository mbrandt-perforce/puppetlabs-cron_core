# frozen_string_literal: true

module CronCoreLitmusManifestHelpers
  def resource_manifest(resource, title, params = {})
    params_str = params.map { |param, value|
      value_str = value.to_s
      value_str = "\"#{value_str}\"" if value.is_a?(String)
      "  #{param} => #{value_str}"
    }.join(",\n")

    <<~MANIFEST
      #{resource} { '#{title}':
      #{params_str}
      }
    MANIFEST
  end

  def file_manifest(path, params = {})
    resource_manifest('file', path, params)
  end

  def cron_manifest(entry_name, params = {})
    resource_manifest('cron', entry_name, params)
  end

  def user_manifest(username, params = {})
    resource_manifest('user', username, params)
  end
end
