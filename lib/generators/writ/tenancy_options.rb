# frozen_string_literal: true

require 'digest'

module Writ
  module Generators
    module TenancyOptions
      extend ActiveSupport::Concern

      included do
        class_option :multi_tenant, type: :boolean, default: false,
                     desc: 'Generate multi-tenant setup with scoping model'
        class_option :scoping_model, type: :string, default: 'Organisation',
                     desc: 'Name of the tenant/scoping model (multi-tenant only)'
        class_option :roleable_model, type: :string, default: 'User', desc: 'Name of the model that has roles'
        class_option :model_namespace, type: :string, default: '', desc: 'Namespace for generated authorization models, e.g. Authorization'
        class_option :roleable_primary_key, type: :string, default: nil,
                     desc: 'Primary-key column on the roleable model (inferred when loaded)'
        class_option :roleable_primary_key_type, type: :string, default: nil,
                     desc: 'Database type for the roleable primary key (inferred when loaded)'
        class_option :scoping_primary_key, type: :string, default: nil,
                     desc: 'Primary-key column on the scoping model (inferred when loaded)'
        class_option :scoping_primary_key_type, type: :string, default: nil,
                     desc: 'Database type for the scoping primary key (inferred when loaded)'
      end

      def initialize(*args)
        super
        names = [roleable_model_name]
        names << scoping_model_name if multi_tenant?
        names << options[:model_namespace] if options[:model_namespace].present?
        if multi_tenant? && roleable_model_name == scoping_model_name
          raise ArgumentError, 'roleable_model and scoping_model must be different models in multi-tenant mode'
        end
        names.each do |name|
          unless name.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/)
            raise ArgumentError, "Invalid model constant or namespace: #{name.inspect}"
          end
        end
        validate_primary_key_options!
        roleable_primary_key
        roleable_primary_key_type
        if multi_tenant?
          scoping_primary_key
          scoping_primary_key_type
        end
      end

      private

      def multi_tenant?
        options[:multi_tenant]
      end

      def scoping_model_name
        options[:scoping_model]
      end

      def roleable_model_name
        options[:roleable_model]
      end

      def host_table_name(model_name)
        model = model_name.safe_constantize
        model && model < ActiveRecord::Base ? model.table_name : model_name.demodulize.tableize
      end

      def host_primary_key(model_name, option)
        configured = options[option]
        return configured if configured.present?

        model = model_name.safe_constantize
        return 'id' unless model && model < ActiveRecord::Base

        primary_key = model.primary_key
        primary_key = 'id' if primary_key.nil? && !model.table_exists?
        unless primary_key.is_a?(String) && primary_key.match?(/\A[a-z_][a-z0-9_]*\z/)
          raise ArgumentError, "#{model_name} must have a single-column primary key with a lowercase SQL identifier"
        end

        primary_key
      end

      def host_primary_key_type(model_name, option)
        configured = options[option]
        return configured if configured.present?

        model = model_name.safe_constantize
        if model && model < ActiveRecord::Base && model.table_exists?
          primary_key = host_primary_key(model_name, option.to_s.sub('_type', '').to_sym)
          column = model.columns_hash[primary_key]
          if column
            return 'bigint' if column.type == :integer && column.limit.to_i >= 8

            return column.type.to_s
          end
          raise ArgumentError, "Cannot infer the type of #{model_name}.#{primary_key}; supply --#{option.to_s.tr('_', '-')}"
        end
        'bigint'
      end

      def validate_primary_key_options!
        %i[roleable_primary_key scoping_primary_key].each do |option|
          value = options[option]
          next if value.blank? || value.match?(/\A[a-z_][a-z0-9_]*\z/)

          raise ArgumentError, "#{option} must be a lowercase SQL identifier"
        end
        %i[roleable_primary_key_type scoping_primary_key_type].each do |option|
          value = options[option]
          next if value.blank? || %w[bigint integer uuid string].include?(value)

          raise ArgumentError, "#{option} must be one of bigint, integer, uuid, or string"
        end
      end

      def roleable_primary_key
        host_primary_key(roleable_model_name, :roleable_primary_key)
      end

      def roleable_primary_key_type
        host_primary_key_type(roleable_model_name, :roleable_primary_key_type)
      end

      def scoping_primary_key
        host_primary_key(scoping_model_name, :scoping_primary_key)
      end

      def scoping_primary_key_type
        host_primary_key_type(scoping_model_name, :scoping_primary_key_type)
      end

      def scoping_table_name
        host_table_name(scoping_model_name)
      end

      def roleable_table_name
        host_table_name(roleable_model_name)
      end

      def scoping_association
        scoping_model_name.demodulize.underscore
      end

      def roleable_association
        roleable_model_name.demodulize.underscore.pluralize
      end

      def roleable_foreign_key
        roleable_model_name.demodulize.foreign_key
      end

      def model_class_name(name)
        [options[:model_namespace].presence, name].compact.join('::')
      end

      def model_table_name(name)
        model_class_name(name).underscore.tr('/', '_').pluralize
      end

      def membership_table_name
        ActiveRecord::ModelSchema.derive_join_table_name(roleable_table_name, model_table_name('Role'))
      end

      def index_name(table, purpose)
        name = "#{table}_#{purpose}"
        name.length <= 63 ? name : "#{name[0, 54]}_#{Digest::SHA256.hexdigest(name)[0, 8]}"
      end

      def namespace_opening
        options[:model_namespace].split('::').map { |name| "module #{name}\n" }.join
      end

      def namespace_closing
        "end\n" * options[:model_namespace].split('::').length
      end
    end
  end
end
