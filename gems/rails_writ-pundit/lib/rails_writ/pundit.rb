# frozen_string_literal: true

require 'rails_writ'
require 'pundit'
require_relative '../writ/pundit/version'
require_relative '../writ/pundit/policy_helpers'
require_relative '../writ/pundit/policy'
require_relative '../writ/pundit/railtie' if defined?(Rails::Railtie)
