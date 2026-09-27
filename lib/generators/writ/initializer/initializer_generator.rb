# frozen_string_literal: true

require 'rails/generators'
require_relative '../tenancy_options'

module Writ
  module Generators
    class InitializerGenerator < Rails::Generators::Base
      include TenancyOptions
      source_root File.expand_path('templates', __dir__)

      desc "Creates a configuration initializer for writ"

      def create_initializer
        template 'initializer.rb.tt', 'config/initializers/writ.rb'
        template 'permissions.rb.tt', 'config/writ/permissions.rb'
      end
    end
  end
end
