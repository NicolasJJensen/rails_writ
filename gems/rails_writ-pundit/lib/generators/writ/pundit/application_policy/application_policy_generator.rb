# frozen_string_literal: true

require 'rails/generators'

module Writ
  module Pundit
    module Generators
      class ApplicationPolicyGenerator < Rails::Generators::Base
        source_root File.expand_path('templates', __dir__)

        desc "Creates the base ApplicationPolicy for Writ::Pundit::Policy"

        def create_application_policy
          template 'application_policy.rb.tt', 'app/policies/application_policy.rb'
        end
      end
    end
  end
end
