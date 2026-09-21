# frozen_string_literal: true

require 'rails/generators'

module Writ
  module Generators
    class ConditionsGenerator < Rails::Generators::Base
      source_root File.expand_path('templates', __dir__)

      desc "Creates a Conditions concern skeleton for shared permission conditions"

      def create_conditions_concern
        template 'conditions.rb.tt', 'app/policies/concerns/conditions.rb'
      end
    end
  end
end
