# frozen_string_literal: true

require 'rails/generators'
require_relative '../tenancy_options'

module Writ
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include TenancyOptions

      desc "Sets up writ: migrations, models, initializer, policies, and roleable injection"

      def verify_roleable_models
        required_roleable_models.each do |model_name, purpose|
          path = "app/models/#{model_name.underscore}.rb"
          next if File.exist?(File.join(destination_root, path))

          raise Thor::Error, "Cannot install writ: #{purpose} model #{model_name} must exist at #{path} for role integration"
        end
      end

      def run_migrations_generator
        generate "writ:migrations", tenancy_args
      end

      def run_models_generator
        generate "writ:models", tenancy_args
      end

      def run_initializer_generator
        generate "writ:initializer", tenancy_args
      end

      def run_application_policy_generator
        generate "writ:application_policy"
      end

      def run_conditions_generator
        generate "writ:conditions"
      end

      def run_roleable_generator
        generate "writ:roleable", roleable_model_name

        if multi_tenant?
          generate "writ:roleable", "#{scoping_model_name} --scoping-model"
        end
      end

      private

      def required_roleable_models
        models = [[roleable_model_name, 'roleable']]
        models << [scoping_model_name, 'scoping'] if multi_tenant?
        models
      end

      def tenancy_args
        args = []
        args << "--multi-tenant" if multi_tenant?
        args << "--scoping-model=#{scoping_model_name}" if multi_tenant?
        args << "--roleable-model=#{roleable_model_name}"
        args << "--model-namespace=#{options[:model_namespace]}" if options[:model_namespace].present?
        args << "--roleable-primary-key=#{options[:roleable_primary_key]}" if options[:roleable_primary_key].present?
        args << "--roleable-primary-key-type=#{options[:roleable_primary_key_type]}" if options[:roleable_primary_key_type].present?
        args << "--scoping-primary-key=#{options[:scoping_primary_key]}" if options[:scoping_primary_key].present?
        args << "--scoping-primary-key-type=#{options[:scoping_primary_key_type]}" if options[:scoping_primary_key_type].present?
        args.join(" ")
      end
    end
  end
end
