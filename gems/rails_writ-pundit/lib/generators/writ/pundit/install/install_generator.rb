# frozen_string_literal: true

require 'generators/writ/install/install_generator'
require_relative '../application_policy/application_policy_generator'

module Writ
  module Pundit
    module Generators
      class InstallGenerator < Writ::Generators::InstallGenerator
        desc 'Installs Writ models and configuration with a Pundit base policy'

        def run_application_policy_generator
          generate 'writ:pundit:application_policy'
        end
      end
    end
  end
end
