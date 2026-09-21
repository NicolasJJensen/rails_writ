# frozen_string_literal: true

module Writ
  module DSL
    class ConfigurationDSL
      def initialize(configuration)
        @configuration = configuration
        # Nested options are dynamic state. The stack prevents later declarations from inheriting closed block defaults.
        @option_stack = [{}]
        @condition_stack = []
      end

      SETTINGS = %i[default_role_name default_scoping_model multi_tenant logger
                    on_missing_condition on_missing_default_scope on_missing_matcher on_condition_error on_invalid_scope_arguments
                    on_invalid_condition_arguments permission_class role_class scope_class
                    permission_scope_class condition_class permission_condition_class
                    permission_source role_source field_default
                    authorization_model_resolver].freeze
      SETTINGS.each do |name|
        define_method("#{name}=") { |value| @configuration.public_send("#{name}=", value) }
      end

      def current_options
        @option_stack.reduce({}) { |acc, opts| acc.merge(opts) }
      end

      VALID_WITH_OPTIONS_KEYS = %i[model role scopes conditions].freeze

      def with_options(options = {}, &block)
        if frozen?
          raise Writ::ConfigurationError,
                "with_options cannot be called on a frozen ConfigurationDSL instance."
        end

        raise ArgumentError, "Block required for with_options" unless block

        unknown_keys = options.keys - VALID_WITH_OPTIONS_KEYS
        if unknown_keys.any?
          raise ArgumentError,
                "Unknown with_options key(s): #{unknown_keys.map { |k| ":#{k}" }.join(', ')}. " \
                "Valid keys: #{VALID_WITH_OPTIONS_KEYS.map { |k| ":#{k}" }.join(', ')}"
        end

        @option_stack.push(options)
        begin
          if block.arity == 1
            block.call(self)
          else
            instance_eval(&block)
          end
        ensure
          @option_stack.pop
        end
      end

      def with_conditions(*entries, &block)
        raise ArgumentError, "Block required for with_conditions" unless block

        names, arguments = normalize_entries(entries, 'condition')
        current = @condition_stack.last || [[], {}]
        merged_names, merged_arguments = merge_condition_entries(current[0], current[1], names, arguments)
        @condition_stack.push([merged_names, merged_arguments])
        begin
          block.arity == 1 ? block.call(self) : instance_eval(&block)
        ensure
          @condition_stack.pop
        end
      end

      def current_conditions
        @condition_stack.last || [[], {}]
      end

      # Register a default scope for a model
      # Default scopes are always applied before permission scopes
      # Only one default scope per model
      # @param model [Class] Model class (optional if in with_options block)
      # @param block [Proc] Scope implementation
      # @example
      #   config.default_scope model: Asset do |context|
      #     Asset.where(organisation: context.organisation)
      #   end
      def default_scope(model: nil, matches: nil, replace: false, declaration_location: nil, &block)
        options = current_options.merge(compact_hash(model: model))
        model_class = options[:model]

        raise ArgumentError, "model: required for default_scope" unless model_class
        raise ArgumentError, "Block required for default_scope" unless block_given?

        @configuration.register_default_scope(model_name: model_class.name, matches: matches, replace: replace,
                                              declaration_location: declaration_location || caller_location, &block)
      end

      # Register scope with metadata and filter implementation
      # @param name [Symbol] Scope name (e.g., :service_industry)
      # @param model [Class] Model class (optional if in with_options block)
      # @param block [Proc] Filter implementation
      # @example
      #   config.scope :service_industry, model: Asset do |context|
      #     Asset.joins(:service_industries).where(service_industries: { id: context.service_industries })
      #   end
      # Description is read from I18n.t("writ.scopes.#{name}")
      def scope(name, model: nil, arguments: {}, matches: nil, replace: false, declaration_location: nil, &block)
        options = current_options.merge(compact_hash(model: model))

        model_class = options[:model]

        raise ArgumentError, "model: required for scope" unless model_class
        raise ArgumentError, "Block required for scope filter" unless block_given?

        model_name = model_class.name

        @configuration.register_scope(model_name: model_name, scope_name: name, arguments: arguments, matches: matches,
                                      replace: replace, declaration_location: declaration_location || caller_location, &block)
      end

      def field_resolver(model: nil, include_global: false, append: false, replace: false, &block)
        raise ArgumentError, "Block required for field_resolver" unless block
        model_class = current_options.merge(compact_hash(model: model))[:model]
        @configuration.register_field_resolver(model_name: model_class&.name, include_global: include_global,
                                               append: append, replace: replace, &block)
      end

      def creation_validator(model: nil, &block)
        raise ArgumentError, "Block required for creation_validator" unless block
        model_class = current_options.merge(compact_hash(model: model))[:model]
        @configuration.register_creation_validator(model_name: model_class&.name, &block)
      end

      def update_validator(model: nil, &block)
        raise ArgumentError, "Block required for update_validator" unless block
        model_class = current_options.merge(compact_hash(model: model))[:model]
        @configuration.register_update_validator(model_name: model_class&.name, &block)
      end

      # Register condition implementation
      # @param name [Symbol] Condition name (e.g., :business_hours, :in_office)
      # @param block [Proc] Condition implementation that returns boolean
      # @example
      #   config.condition :business_hours do |context|
      #     (9..17).cover?(Time.current.hour) && !Time.current.weekend?
      #   end
      # Description is read from I18n.t("writ.conditions.#{name}")
      def condition(name, arguments: {}, replace: false, declaration_location: nil, &block)
        raise ArgumentError, "Block required for condition" unless block_given?

        @configuration.register_condition(name: name, arguments: arguments, replace: replace,
                                          declaration_location: declaration_location || caller_location, &block)
      end

      def allow_missing_default_scope(model: nil)
        model_class = current_options.merge(compact_hash(model: model))[:model]
        raise ArgumentError, 'model: required for allow_missing_default_scope' unless model_class

        @configuration.register_allow_missing_default_scope(model_name: model_class.name)
      end

      # Register single permission
      # @param action [Symbol] Single action (e.g., :read, :create)
      # @param model [Class] Model class (optional if in with_options block)
      # @param role [Symbol, String] Role name (optional if in with_options block)
      # @param scopes [Array<Symbol>] Array of scope names (default: [])
      # @param conditions [Array<Symbol>] Array of condition names (default: [])
      # @example
      #   config.permission :read, model: Asset, role: :Technician, scopes: [:service_industry]
      #   config.permission :update, model: Asset, role: :Technician, scopes: [:service_industry], conditions: [:business_hours, :in_office]
      def permission(action, model: nil, role: nil, scopes: nil, conditions: nil)
        options = current_options.merge(compact_hash(model: model, role: role, scopes: scopes, conditions: conditions))

        scope_names, scope_arguments = normalize_entries(coerce_entry_list(options[:scopes]), 'scope')
        explicit_condition_names, explicit_condition_arguments = normalize_entries(coerce_entry_list(options[:conditions]), 'condition')
        lexical_names, lexical_arguments = current_conditions
        condition_names, condition_arguments = merge_condition_entries(
          lexical_names, lexical_arguments, explicit_condition_names, explicit_condition_arguments
        )

        register_permission(
          action,
          model: options[:model],
          role: options[:role],
          scopes: scope_names,
          scope_arguments: scope_arguments,
          condition_names: condition_names,
          condition_arguments: condition_arguments
        )
      end

      def permission_with_entries(action, model:, role:, scopes: nil, condition_names:, condition_arguments: {})
        scope_names, scope_arguments = normalize_entries(coerce_entry_list(scopes), 'scope')

        register_permission(
          action,
          model: model,
          role: role,
          scopes: scope_names,
          scope_arguments: scope_arguments,
          condition_names: condition_names,
          condition_arguments: condition_arguments
        )
      end

      def normalize_condition_entries(entries)
        normalize_entries(entries, 'condition')
      end

      def merge_condition_entries(left_names, left_arguments, right_names, right_arguments)
        names = left_names.dup
        arguments = left_arguments.deep_dup
        right_names.each do |name|
          if names.include?(name)
            left_args = arguments[name] || {}
            right_args = right_arguments[name] || {}
            left_canonical = @configuration.canonical_arguments(name => left_args).fetch(name, {})
            right_canonical = @configuration.canonical_arguments(name => right_args).fetch(name, {})
            unless left_canonical == right_canonical
              raise ArgumentError, "Conflicting arguments for condition '#{name}'"
            end
            next
          end
          names << name
          arguments[name] = right_arguments[name].deep_dup if right_arguments.key?(name)
        end
        [names, arguments]
      end

      private

      def caller_location
        location = caller_locations(2, 1).first
        "#{location.path}:#{location.lineno}"
      end

      def register_permission(action, model:, role:, scopes:, scope_arguments:, condition_names:, condition_arguments:)
        raise ArgumentError, "model: required for permission" unless model
        raise ArgumentError, "role: required for permission" unless role
        raise ArgumentError, "action must be a single symbol, not #{action.class}" unless action.is_a?(Symbol)
        unless action.to_s.match?(Writ::NAME_FORMAT)
          raise ArgumentError,
                "Invalid action :#{action} for #{model.name}/#{role}. " \
                "Actions must be lowercase, start with a letter, and contain only letters, numbers, and underscores"
        end

        @configuration.register_permission(
          model: model.name,
          role: role,
          action: action,
          scopes: scopes,
          conditions: condition_names,
          scope_arguments: scope_arguments,
          condition_arguments: condition_arguments
        )
      end

      public

      # Register accessible fields for a role/model combination
      # @param fields [Symbol, Array] :all or array of field names or empty array
      # @param model [Class] Model class (optional if in with_options block)
      # @param role [Symbol, String] Role name (optional if in with_options block)
      # @example
      #   config.accessible_fields :all, model: Asset, role: :Technician
      #   config.accessible_fields [:name, :email], model: User, role: :'Default Role'
      #   config.accessible_fields [], model: Asset, role: :Admin  # Empty = no field access
      def accessible_fields(fields, model: nil, role: nil, action: nil)
        unless fields == :all || fields.is_a?(Array)
          raise ArgumentError, "fields must be :all or an Array, got #{fields.class}"
        end

        options = current_options.merge(compact_hash(model: model, role: role))

        model_class = options[:model]
        role_name = options[:role]

        raise ArgumentError, "model: required for accessible_fields" unless model_class
        raise ArgumentError, "role: required for accessible_fields" unless role_name

        model_name = model_class.name

        @configuration.register_accessible_fields(
          model: model_name,
          role: role_name,
          fields: fields, action: action
        )
      end

      private

      # nil inherits nested defaults, while [] deliberately removes inherited scopes or conditions.
      def compact_hash(hash)
        hash.compact
      end

      # Coerce a scopes:/conditions: value into a list of entries. Accepts an array,
      # a single symbol/string, or a single {name => arguments} hash.
      def coerce_entry_list(value)
        return [] if value.nil?
        value.is_a?(Array) ? value : [value]
      end

      # Split a list of entries (symbols/strings and {name => arguments} hashes) into
      # sorted-by-insertion name list + a {name => arguments} hash. Rejects malformed entries.
      # @return [Array(Array<String>, Hash)]
      def normalize_entries(list, label)
        names = []
        arguments = {}

        list.each do |entry|
          if entry.is_a?(Hash)
            unless entry.size == 1
              raise ArgumentError, "Malformed #{label} entry #{entry.inspect}: expected a single { name => arguments } pair"
            end
            name, args = entry.first
            name = name.to_s
            unless args.is_a?(Hash)
              raise ArgumentError, "Malformed #{label} entry for '#{name}': arguments must be a Hash, got #{args.class}"
            end
            raise ArgumentError, "Duplicate #{label} '#{name}' in permission" if names.include?(name)
            names << name
            arguments[name] = args unless args.empty?
          else
            name = entry.to_s
            raise ArgumentError, "Duplicate #{label} '#{name}' in permission" if names.include?(name)
            names << name
          end
        end

        [names, arguments]
      end

    end
  end
end
