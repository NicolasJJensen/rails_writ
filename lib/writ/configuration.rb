# frozen_string_literal: true

module Writ
  class Configuration
    class << self
      attr_accessor :default_role_name, :default_scoping_model, :multi_tenant
      attr_writer :logger

      def logger
        @logger ||= if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
                      Rails.logger
                    else
                      require 'logger'
                      Logger.new($stdout)
                    end
      end
      # Controls behavior when a condition referenced by a permission is not registered.
      # :raise — raises ConditionNotFoundError (default, good for dev/test)
      # :deny  — silently denies the permission and logs an error (good for production)
      VALID_MISSING_CONDITION_MODES = %i[raise deny].freeze

      def on_missing_condition=(value)
        unless VALID_MISSING_CONDITION_MODES.include?(value)
          raise ArgumentError, "on_missing_condition must be one of #{VALID_MISSING_CONDITION_MODES.inspect}, got #{value.inspect}"
        end
        @on_missing_condition = value
      end

      def on_missing_condition
        @on_missing_condition || :raise
      end

      VALID_MISSING_MATCHER_MODES = %i[raise warning skip].freeze

      def on_missing_matcher=(value)
        unless VALID_MISSING_MATCHER_MODES.include?(value)
          raise ArgumentError, "on_missing_matcher must be one of #{VALID_MISSING_MATCHER_MODES.inspect}, got #{value.inspect}"
        end
        @on_missing_matcher = value
      end

      def on_missing_matcher
        @on_missing_matcher || :raise
      end

      VALID_MISSING_DEFAULT_SCOPE_MODES = %i[raise warning skip].freeze

      def on_missing_default_scope=(value)
        unless VALID_MISSING_DEFAULT_SCOPE_MODES.include?(value)
          raise ArgumentError, "on_missing_default_scope must be one of #{VALID_MISSING_DEFAULT_SCOPE_MODES.inspect}, got #{value.inspect}"
        end
        @on_missing_default_scope = value
      end

      def on_missing_default_scope
        # Require an explicit choice so an omitted declaration is distinguishable from intentional shared access.
        @on_missing_default_scope || :raise
      end

      # Controls behavior when a registered condition raises an error during evaluation.
      # Separate from on_missing_condition so configuration errors (missing conditions) and
      # runtime bugs (condition code that crashes) are handled independently.
      # :raise — re-raises the error (default, surfaces bugs in dev/test and production)
      # :deny  — silently denies the permission and logs the error
      VALID_CONDITION_ERROR_MODES = %i[raise deny].freeze

      def on_condition_error=(value)
        unless VALID_CONDITION_ERROR_MODES.include?(value)
          raise ArgumentError, "on_condition_error must be one of #{VALID_CONDITION_ERROR_MODES.inspect}, got #{value.inspect}"
        end
        @on_condition_error = value
      end

      def on_condition_error
        @on_condition_error || :raise
      end

      # Controls behavior when a permission's stored scope arguments fail validation
      # against the registered scope schema at runtime (i.e. a corrupt/invalid DB row).
      # :raise — raises InvalidArgumentsError (default). NOTE: this aborts the ENTIRE access
      #          check, not just the offending permission — a single corrupt row makes
      #          authorization, validation, or filter can raise for that call. Good for
      #          dev/test where you want bad data surfaced loudly.
      # :deny  — logs the error and excludes only the offending permission; other permissions
      #          still apply. RECOMMENDED IN PRODUCTION so one bad row can't take down access
      #          checks for a whole model/action.
      VALID_INVALID_SCOPE_ARGUMENTS_MODES = %i[raise deny].freeze

      def on_invalid_scope_arguments=(value)
        unless VALID_INVALID_SCOPE_ARGUMENTS_MODES.include?(value)
          raise ArgumentError, "on_invalid_scope_arguments must be one of #{VALID_INVALID_SCOPE_ARGUMENTS_MODES.inspect}, got #{value.inspect}"
        end
        @on_invalid_scope_arguments = value
      end

      def on_invalid_scope_arguments
        @on_invalid_scope_arguments || :raise
      end

      # Controls behavior when a permission's stored condition arguments fail validation.
      # :raise — raises InvalidArgumentsError (default). As with on_invalid_scope_arguments,
      #          this aborts the entire access check, not just the offending permission.
      # :deny  — logs the error and treats the condition as unmet (excludes only that
      #          permission). RECOMMENDED IN PRODUCTION.
      VALID_INVALID_CONDITION_ARGUMENTS_MODES = %i[raise deny].freeze

      def on_invalid_condition_arguments=(value)
        unless VALID_INVALID_CONDITION_ARGUMENTS_MODES.include?(value)
          raise ArgumentError, "on_invalid_condition_arguments must be one of #{VALID_INVALID_CONDITION_ARGUMENTS_MODES.inspect}, got #{value.inspect}"
        end
        @on_invalid_condition_arguments = value
      end

      def on_invalid_condition_arguments
        @on_invalid_condition_arguments || :raise
      end

      MODEL_DEFAULTS = {
        permission: 'Permission', role: 'Role', scope: 'Scope',
        permission_scope: 'PermissionScope', condition: 'Condition',
        permission_condition: 'PermissionCondition'
      }.freeze

      MODEL_DEFAULTS.each do |key, default|
        define_method("#{key}_class=") do |value|
          @model_names ||= {}
          @model_names[key] = value.nil? ? default : (value.is_a?(Class) ? value.name : value.to_s)
        end
        define_method("#{key}_class") do
          name = (@model_names || {}).fetch(key, default)
          name.constantize
        rescue NameError
          raise ConfigurationError, "Writ could not find the #{name} model. Configure #{key}_class with a constant name."
        end
      end

      def model_class_name(key)
        (@model_names || {}).fetch(key) { MODEL_DEFAULTS.fetch(key) }
      end

      def role_class_name
        model_class_name(:role)
      end

      attr_accessor :permission_source, :role_source

      # Resolves the model name used to look up authorization metadata. The
      # queried relation remains the concrete model, so STI subtype predicates
      # are retained. By default policies are exact-model policies; hosts that
      # intentionally define one policy for an STI hierarchy may return
      # +model.base_class+ here.
      attr_writer :authorization_model_resolver

      def authorization_model_resolver
        @authorization_model_resolver || ->(model) { model }
      end

      def authorization_model_for(model)
        resolved = authorization_model_resolver.call(model)
        unless resolved.is_a?(Class) && resolved < ActiveRecord::Base
          raise ConfigurationError, 'authorization_model_resolver must return an ActiveRecord model class'
        end
        unless resolved.base_class == model.base_class && resolved.table_name == model.table_name && model <= resolved
          raise ConfigurationError,
                "authorization_model_resolver returned #{resolved.name} for #{model.name}; " \
                'resolved models must share the same STI base class and table'
        end
        resolved
      end

      def field_default
        @field_default || :all
      end

      def field_default=(value)
        raise ArgumentError, 'field_default must be :all or an array' unless value == :all || value.is_a?(Array)
        @field_default = value == :all ? :all : value.map(&:to_s).freeze
      end

      def permissions_for(context)
        return permission_source.call(context) if permission_source
        context.permissions if context.respond_to?(:permissions)
      end

      def roles_for(context)
        return role_source.call(context) if role_source
        context.roles if context.respond_to?(:roles)
      end

      def rebuild!
        candidate = Writ::Logic::Registry.new
        previous = Thread.current[:writ_building_registry]
        Thread.current[:writ_building_registry] = candidate
        candidate.reload do
          # Replay initializer settings before loading model-dependent definitions.
          (@configure_blocks || []).each { |block| apply_configuration(&block) }
          yield if block_given?
        end
        # Publish only after validation, preserving the last working registry when rebuilding fails.
        @registry = candidate
      ensure
        Thread.current[:writ_building_registry] = previous
      end

      # Main DSL entry point. Uses instance_eval so self inside the block
      # is already the ConfigurationDSL instance; no block parameter needed.
      # @example
      #   Writ.configure do
      #     scope :service_industry, model: Asset do |context|
      #       Asset.joins(:service_industries).where(service_industries: { id: context.service_industry_ids })
      #     end
      #   end
      def configure(&block)
        raise ArgumentError, 'Block required' unless block

        return apply_configuration(&block) if building_registry?

        candidate = registry.dup_for_configuration
        previous = Thread.current[:writ_building_registry]
        Thread.current[:writ_building_registry] = candidate
        apply_configuration(&block)
        # A failed initializer must not leave a subset of its declarations live until the next reload.
        @registry = candidate
        (@configure_blocks ||= []) << block
      ensure
        # A configure call inside rebuild! must leave the enclosing candidate active.
        Thread.current[:writ_building_registry] = previous if candidate
      end

      # Reset all memoized class references and clear the active registry.
      # Called during code reload (to_prepare) to avoid stale Zeitwerk references.
      #
      # Accepts an optional block for re-registration. When a block is given,
      # the block runs while the registry is in reloading state, and
      # reload_complete! is called automatically afterward.
      # Without a block, previously recorded configure blocks are preserved and
      # will be replayed by a later rebuild!. The caller must re-register any
      # declarations needed immediately, then call registry.reload_complete!.
      #
      # @example With block (preferred)
      #   Configuration.reset! do
      #     load Rails.root.join('config/writ/permissions.rb')
      #   end
      #
      # @example Without block (backward compatible; configure blocks are retained)
      #   Configuration.reset!
      #   # ... re-register declarations needed immediately ...
      #   Configuration.registry.reload_complete!
      def reset!(&block)
        if block
          rebuild!(&block)
        else
          @registry = Writ::Logic::Registry.new
          @registry.clear!
        end
      end

      # Lazily initialized singleton registry shared across the app.
      # All DSL registrations, Generator reads, and Access lookups go through this instance.
      # @return [Writ::Logic::Registry]
      def registry
        Thread.current[:writ_building_registry] || (@registry ||= Writ::Logic::Registry.new)
      end

      def register_scope(model_name:, scope_name:, arguments: {}, matches: nil, replace: false, declaration_location: nil, &block)
        registry.register_scope(model_name: model_name, scope_name: scope_name, arguments: arguments, matches: matches, replace: replace, declaration_location: declaration_location || direct_declaration_location, &block)
      end

      def register_default_scope(model_name:, matches: nil, replace: false, declaration_location: nil, &block)
        registry.register_default_scope(model_name: model_name, matches: matches, replace: replace, declaration_location: declaration_location || direct_declaration_location, &block)
      end

      def register_condition(name:, arguments: {}, replace: false, declaration_location: nil, &block)
        registry.register_condition(name: name, arguments: arguments, replace: replace, declaration_location: declaration_location || direct_declaration_location, &block)
      end

      def register_field_resolver(model_name: nil, include_global: false, append: false, replace: false, &block)
        registry.register_field_resolver(model_name: model_name, include_global: include_global, append: append, replace: replace, &block)
      end

      def register_creation_validator(model_name: nil, &block)
        registry.register_creation_validator(model_name: model_name, &block)
      end

      def register_update_validator(model_name: nil, &block)
        registry.register_update_validator(model_name: model_name, &block)
      end

      def register_allow_missing_default_scope(model_name:)
        registry.register_allow_missing_default_scope(model_name: model_name)
      end

      def building_registry?
        Thread.current[:writ_building_registry]
      end

      def direct_declaration_location
        location = caller_locations(2, 1).first
        "#{location.path}:#{location.lineno}"
      end

      def apply_configuration(&block)
        dsl = Writ::DSL::ConfigurationDSL.new(self)
        dsl.instance_eval(&block)
      end

      # Returns the role description with I18n fallback.
      # Registry stores only explicit descriptions; this method provides the
      # fallback layer so the Registry stays a pure data store.
      # @param role_name [String, Symbol] Role name
      # @return [String] Stored description or I18n/humanized fallback
      def role_description_with_fallback(role_name)
        registry.role_description(role_name) ||
          I18n.t("writ.roles.#{role_name}", default: role_name.to_s.humanize)
      end

      delegate :get_scope_callable, :scope_callable_registered?,
               :scope_callables_for, :all_scope_callables, :remove_scope_callable,
               :models, :all_configured_models, :scopes_for,
               :get_default_scope, :default_scope_registered?,
               :remove_default_scope,
               :get_scope_definition, :all_scope_metadata, :scope_arguments_schema,
               :field_resolver_for, :field_resolvers_for,
               :creation_validators_for,
               :update_validators_for,
               :get_condition, :condition_registered?,
               :all_conditions, :remove_condition,
               :all_condition_metadata, :condition_arguments_schema, :canonical_arguments,
               :register_permission, :all_permissions,
               :register_accessible_fields, :all_accessible_fields,
               :register_role_description, :role_description, :role_description_explicit?,
               :clear!, :reload_complete!, :validate_references!,
               to: :registry
    end
  end
end
