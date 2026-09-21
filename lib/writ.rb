# frozen_string_literal: true

require 'active_support'
require 'active_record'

require_relative 'writ/version'
require_relative 'writ/errors'
require_relative 'writ/logic/argument_validator'
require_relative 'writ/logic/registry'
require_relative 'writ/configuration'
require_relative 'writ/dsl/configuration_dsl'
require_relative 'writ/diagnostics'
require_relative 'writ/access'
require_relative 'writ/record_lookup'
require_relative 'writ/generator'
require_relative 'writ/permission_migration'
require_relative 'writ/roleable'
require_relative 'writ/permission_associations'
require_relative 'writ/permission_join_validations'
require_relative 'writ/policy_helpers'
require_relative 'writ/engine' if defined?(Rails::Engine)

# Main Writ module
module Writ
  NAME_FORMAT = /\A[a-z][a-z0-9_]*\z/
  # Configure permissions using DSL. Uses instance_eval so self inside
  # the block is already the ConfigurationDSL instance; no block parameter needed.
  # @example
  #   Writ.configure do
  #     scope :service_industry, model: Asset do |context|
  #       Asset.joins(:service_industries).where(service_industries: { id: context.service_industry_ids })
  #     end
  #   end
  def self.configure(&block)
    Configuration.configure(&block)
  end
end
