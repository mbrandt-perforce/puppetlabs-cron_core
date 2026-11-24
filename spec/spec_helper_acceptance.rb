# frozen_string_literal: true

require 'puppet_litmus'
PuppetLitmus.configure!

require_relative 'spec_helper_acceptance_local' if File.file?(File.join(__dir__, 'spec_helper_acceptance_local.rb'))
