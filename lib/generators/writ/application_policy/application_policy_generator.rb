# frozen_string_literal: true

require 'rails/generators'
require_relative '../conditions/conditions_generator'

module Writ
  module Generators
    class ApplicationPolicyGenerator < Rails::Generators::Base
      source_root File.expand_path('templates', __dir__)

      desc "Creates the base ApplicationPolicy with Writ::PolicyHelpers"

      def create_application_policy
        unless File.exist?(File.join(destination_root, 'app/policies/concerns/conditions.rb'))
          invoke Writ::Generators::ConditionsGenerator
        end
        template 'application_policy.rb.tt', 'app/policies/application_policy.rb'
      end
    end
  end
end
