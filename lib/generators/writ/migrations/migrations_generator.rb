# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'
require_relative '../tenancy_options'

module Writ
  module Generators
    class MigrationsGenerator < Rails::Generators::Base
      include Rails::Generators::Migration
      include TenancyOptions

      source_root File.expand_path('templates', __dir__)

      desc "Creates the database migrations for writ"

      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def create_roles_migration
        migration_template 'create_roles.rb.tt', "db/migrate/create_#{model_table_name('Role')}.rb"
      end

      def create_permissions_migration
        migration_template 'create_permissions.rb.tt', "db/migrate/create_#{model_table_name('Permission')}.rb"
      end

      # Scopes/conditions catalog tables and their permission join tables.
      # Emitted in FK-safe order: catalog tables before the join tables that reference them.
      def create_scopes_migration
        migration_template 'create_scopes.rb.tt', "db/migrate/create_#{model_table_name('Scope')}.rb"
      end

      def create_permission_scopes_migration
        migration_template 'create_permission_scopes.rb.tt', "db/migrate/create_#{model_table_name('PermissionScope')}.rb"
      end

      def create_conditions_migration
        migration_template 'create_conditions.rb.tt', "db/migrate/create_#{model_table_name('Condition')}.rb"
      end

      def create_permission_conditions_migration
        migration_template 'create_permission_conditions.rb.tt', "db/migrate/create_#{model_table_name('PermissionCondition')}.rb"
      end

      def create_join_table_migration
        migration_template 'create_join_table.rb.tt',
                           "db/migrate/create_join_table_#{model_table_name('Role')}_#{roleable_table_name}.rb"
      end

      def create_default_role_migration
        return unless multi_tenant?

        migration_template 'add_default_role.rb.tt',
                           "db/migrate/add_default_role_to_#{scoping_table_name}.rb"
      end

      private

      def migration_version
        "[#{ActiveRecord::Migration.current_version}]"
      end
    end
  end
end
