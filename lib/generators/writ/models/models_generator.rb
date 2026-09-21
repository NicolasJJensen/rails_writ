# frozen_string_literal: true

require 'rails/generators'
require_relative '../tenancy_options'

module Writ
  module Generators
    class ModelsGenerator < Rails::Generators::Base
      include TenancyOptions

      source_root File.expand_path('templates', __dir__)

      desc "Creates the authorization models for writ"

      def create_role_model
        template 'role.rb.tt', "app/models/#{model_class_name('Role').underscore}.rb"
      end

      def create_permission_model
        template 'permission.rb.tt', "app/models/#{model_class_name('Permission').underscore}.rb"
      end

      def create_scope_model
        template 'scope.rb.tt', "app/models/#{model_class_name('Scope').underscore}.rb"
      end

      def create_permission_scope_model
        template 'permission_scope.rb.tt', "app/models/#{model_class_name('PermissionScope').underscore}.rb"
      end

      def create_condition_model
        template 'condition.rb.tt', "app/models/#{model_class_name('Condition').underscore}.rb"
      end

      def create_permission_condition_model
        template 'permission_condition.rb.tt', "app/models/#{model_class_name('PermissionCondition').underscore}.rb"
      end

    end
  end
end
