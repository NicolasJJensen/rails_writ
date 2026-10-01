# frozen_string_literal: true

module Writ
  module Logic
    # Central in-memory store for all DSL-registered configuration.
    # Holds scope callables (scope implementations), default scopes, conditions, permissions,
    # and accessible fields. Populated at boot via the DSL (ConfigurationDSL) or
    # direct API calls, then read by Generator (to create DB records) and Access
    # (to evaluate permissions at runtime).
    class Registry
      def initialize
        @scope_definitions = {}
        @default_scope_definitions = {}
        @condition_definitions = {}
        @permissions = {}
        @accessible_fields = {}
        @role_descriptions = {}
        @field_resolvers = {}
        @creation_validators = Hash.new { |hash, key| hash[key] = [] }
        @update_validators = Hash.new { |hash, key| hash[key] = [] }
        @missing_default_scope_exemptions = Set.new
        @reloading = false
      end

      def dup_for_configuration
        copy = self.class.new
        copy.instance_variable_set(:@scope_definitions, @scope_definitions.deep_dup)
        copy.instance_variable_set(:@default_scope_definitions, @default_scope_definitions.deep_dup)
        copy.instance_variable_set(:@condition_definitions, @condition_definitions.deep_dup)
        copy.instance_variable_set(:@permissions, @permissions.deep_dup)
        copy.instance_variable_set(:@accessible_fields, @accessible_fields.deep_dup)
        copy.instance_variable_set(:@role_descriptions, @role_descriptions.deep_dup)
        copy.instance_variable_set(:@field_resolvers, @field_resolvers.deep_dup)
        copy.instance_variable_set(:@creation_validators, copy_validator_store(@creation_validators))
        copy.instance_variable_set(:@update_validators, copy_validator_store(@update_validators))
        copy.instance_variable_set(:@missing_default_scope_exemptions, @missing_default_scope_exemptions.deep_dup)
        copy
      end

      # Register a scope block for a model and scope
      # @param model_name [String] The model name (e.g., 'Asset', 'User')
      # @param scope_name [String, Symbol] The scope name (e.g., 'service_industry', :created)
      # @param block [Proc] The scope implementation
      # @example Register with block
      #   registry.register_scope(model_name: 'Asset', scope_name: 'service_industry') do |context|
      #     Asset.joins(:service_industries).where(service_industries: { id: context.service_industries })
      #   end
      def register_scope(model_name:, scope_name:, arguments: {}, matches: nil, validate: nil, replace: false, declaration_location: nil, &block)
        source_location = declaration_location || caller_location
        unless scope_name.to_s.match?(Writ::NAME_FORMAT)
          raise ArgumentError,
                "Scope name '#{scope_name}' is invalid. Must be lowercase, start with a letter, " \
                "and contain only letters, numbers, and underscores"
        end

        arguments ||= {}
        Writ::Logic::ArgumentValidator.validate_schema!(arguments, "scope '#{scope_name}' on '#{model_name}'")
        arguments = arguments.deep_dup

        resolved = block
        raise Writ::InvalidScopeError,
              "Must provide a block for scope '#{scope_name}' on '#{model_name}'" unless resolved
        validate_callable_arity!(resolved, scope_name, model_name, has_arguments: arguments.any?)

        validate_callable!(validate, 'scope validator') if validate
        validate_matcher!(matches, arguments.any? ? 3 : 2)
        model_key = model_name.to_s
        scope_key = scope_name.to_s
        existing = @scope_definitions.dig(model_key, scope_key)
        # A fresh registry only removes declarations from an earlier generation.
        # A repeated key in this generation remains an ambiguous host declaration.
        reject_duplicate_declaration!("scope '#{scope_key}' on '#{model_key}'", existing, replace, source_location) if existing
        @scope_definitions[model_key] ||= {}
        @scope_definitions[model_key][scope_key] = {
          callable: resolved,
          arguments: arguments,
          matches: matches,
          validate: validate,
          declaration_location: source_location
        }
        resolved
      end

      # Register a default scope for a model
      # Default scopes are always applied before permission scopes
      # Only one default scope per model. Use replace: true to replace it.
      # @param model_name [String] The model name (e.g., 'Asset', 'User')
      # @param block [Proc] The scope implementation
      # @example Register with block
      #   registry.register_default_scope(model_name: 'Asset') do |context|
      #     Asset.where(organisation: context.organisation)
      #   end
      def register_default_scope(model_name:, matches: nil, validate: nil, replace: false, declaration_location: nil, &block)
        source_location = declaration_location || caller_location
        resolved = block
        raise Writ::InvalidScopeError,
              "Must provide a block for default_scope on '#{model_name}'" unless resolved
        validate_callable_arity!(resolved, :default_scope, model_name)

        model_key = model_name.to_s
        existing = @default_scope_definitions[model_key]
        # Explicit replacement prevents a later policy from silently changing a shared access boundary.
        reject_duplicate_declaration!("default_scope on '#{model_key}'", existing, replace, source_location) if existing
        validate_callable!(validate, 'default scope validator') if validate
        validate_matcher!(matches, 2)
        @default_scope_definitions[model_key] = {
          callable: resolved,
          matches: matches,
          validate: validate,
          declaration_location: source_location
        }
      end

      # Get the default scope for a model
      # @param model_name [String] The model name
      # @return [Proc, nil] The default scope callable or nil if not found
      def get_default_scope_validator(model_name:)
        @default_scope_definitions.dig(model_name.to_s, :validate)
      end

      def get_scope_validator(model_name:, scope_name:)
        @scope_definitions.dig(model_name.to_s, scope_name.to_s, :validate)
      end

      def get_default_scope(model_name:)
        @default_scope_definitions.dig(model_name.to_s, :callable)
      end

      # Check if a model has a registered default scope
      # @param model_name [String] The model name
      # @return [Boolean] true if default scope is registered
      def default_scope_registered?(model_name:)
        !get_default_scope(model_name: model_name).nil?
      end

      # Get the argument schema for a scope, or nil if none declared.
      # @return [Hash, nil]
      def scope_arguments_schema(model_name:, scope_name:)
        schema = @scope_definitions.dig(model_name.to_s, scope_name.to_s, :arguments)
        schema && !schema.empty? ? schema.deep_dup : nil
      end

      # Register a condition with its implementation
      # @param name [Symbol, String] Condition name (e.g., :business_hours, :in_office)
      # @param block [Proc] Condition implementation that returns boolean
      # @example
      #   register_condition(name: :business_hours) do |context|
      #     (9..17).cover?(Time.current.hour) && !Time.current.weekend?
      #   end
      def register_condition(name:, arguments: {}, replace: false, declaration_location: nil, &block)
        source_location = declaration_location || caller_location
        unless name.to_s.match?(Writ::NAME_FORMAT)
          raise ArgumentError,
                "Condition name '#{name}' is invalid. Must be lowercase, start with a letter, " \
                "and contain only letters, numbers, and underscores"
        end

        arguments ||= {}
        Writ::Logic::ArgumentValidator.validate_schema!(arguments, "condition '#{name}'")
        arguments = arguments.deep_dup

        resolved = block
        raise ArgumentError, "Block required for condition '#{name}'" unless resolved
        validate_callable_arity!(resolved, name, 'condition', has_arguments: arguments.any?)

        key = name.to_s
        existing = @condition_definitions[key]
        # Conditions are global names, so a second implementation can change unrelated policy grants.
        reject_duplicate_declaration!("condition '#{key}'", existing, replace, source_location) if existing

        @condition_definitions[key] = {
          callable: resolved,
          arguments: arguments,
          declaration_location: source_location
        }
      end

      # Get the argument schema for a condition, or nil if none declared.
      # @return [Hash, nil]
      def condition_arguments_schema(name:)
        schema = @condition_definitions.dig(name.to_s, :arguments)
        schema && !schema.empty? ? schema.deep_dup : nil
      end

      # Introspection: all condition metadata (deep copy)
      def all_condition_metadata
        @condition_definitions.transform_values { |definition| { arguments: definition[:arguments] } }.deep_dup
      end

      # Get a condition implementation
      # @param name [Symbol, String] Condition name
      # @return [Proc, nil] The condition callable or nil if not found
      def get_condition(name:)
        @condition_definitions.dig(name.to_s, :callable)
      end

      # Check if a condition is registered
      # @param name [Symbol, String] Condition name
      # @return [Boolean] true if condition is registered
      def condition_registered?(name:)
        !get_condition(name: name).nil?
      end

      # Get all registered conditions
      # @return [Array<String>] Array of condition names
      def all_conditions
        @condition_definitions.keys
      end

      def register_field_resolver(model_name:, include_global: false, append: false, replace: false, &block)
        resolved = block
        validate_callable!(resolved, 'field_resolver')
        validate_hook_signature!(resolved, %i[context action record fields], 'field_resolver')
        unless [true, false].include?(include_global)
          raise ArgumentError, 'include_global must be a boolean'
        end
        if append && replace
          raise ArgumentError, 'field_resolver cannot use append: true and replace: true together'
        end
        key = model_name&.to_s
        definitions = @field_resolvers[key] ||= []
        if definitions.any? && !append && !replace
          first_location = definitions.first[:declaration_location] || 'unknown location'
          conflicting_location = callable_source_location(resolved)
          raise Writ::ConfigurationError,
                "Duplicate declaration for field_resolver on '#{key || 'global'}'. First declaration: #{first_location}. " \
                "Conflicting declaration: #{conflicting_location}. " \
                'Pass append: true to compose it or replace: true to replace it.'
        end

        definitions.clear if replace
        definitions << { callable: resolved, include_global: include_global,
                         declaration_location: callable_source_location(resolved) }
        resolved
      end

      def field_resolver_for(model_name:)
        @field_resolvers[model_name&.to_s]&.last&.dup
      end

      def field_resolvers_for(model_name:)
        (@field_resolvers[model_name&.to_s] || []).map(&:dup)
      end

      def register_creation_validator(model_name: nil, &block)
        register_validator(@creation_validators, model_name, block, 'creation_validator')
      end

      def register_update_validator(model_name: nil, &block)
        register_validator(@update_validators, model_name, block, 'update_validator')
      end

      def creation_validators_for(model_name:)
        validators_for(@creation_validators, model_name)
      end

      def update_validators_for(model_name:)
        validators_for(@update_validators, model_name)
      end

      # Remove a scope callable from the registry
      # @param model_name [String] The model name
      # @param scope_name [String, Symbol] The scope name to remove
      # @return [Proc, nil] The removed callable or nil if not found
      def remove_scope_callable(model_name:, scope_name:)
        model_key = model_name.to_s
        scope_key = scope_name.to_s
        removed = @scope_definitions[model_key]&.delete(scope_key)&.fetch(:callable)
        @scope_definitions.delete(model_key) if @scope_definitions[model_key]&.empty?
        removed
      end

      alias remove_scope remove_scope_callable

      # Remove a default scope from the registry
      # @param model_name [String] The model name
      # @return [Proc, nil] The removed default scope callable or nil if not found
      def remove_default_scope(model_name:)
        @default_scope_definitions.delete(model_name.to_s)&.fetch(:callable)
      end

      # Remove a condition from the registry
      # @param name [Symbol, String] Condition name to remove
      # @return [Proc, nil] The removed condition proc or nil if not found
      def remove_condition(name:)
        @condition_definitions.delete(name.to_s)&.fetch(:callable)
      end

      # Register a single permission
      # @param model [String] Model name
      # @param role [String, Symbol] Role name
      # @param action [Symbol] Action (:read, :create, :update, :delete)
      # @param scopes [Array<Symbol>] Array of scope names
      # @param conditions [Array<Symbol>] Array of condition names (default: [])
      def register_permission(model:, role:, action:, scopes:, conditions: [], scope_arguments: {}, condition_arguments: {})
        raise ArgumentError, "scopes must be an Array, got #{scopes.class}" unless scopes.is_a?(Array)
        raise ArgumentError, "conditions must be an Array, got #{conditions.class}" unless conditions.is_a?(Array)

        unless action.to_s.match?(Writ::NAME_FORMAT)
          raise Writ::InvalidActionError,
                "Invalid action '#{action}'. Actions must be lowercase, start with a letter, " \
                "and contain only letters, numbers, and underscores"
        end

        validate_argument_key_collisions!(scope_arguments, 'Scope arguments')
        validate_argument_key_collisions!(condition_arguments, 'Condition arguments')

        @permissions[role.to_s] ||= {}
        @permissions[role.to_s][model.to_s] ||= []

        new_entry = {
          action: action.to_sym,
          scopes: scopes.map(&:to_s).sort,
          conditions: conditions.map(&:to_s).sort,
          scope_arguments: canonical_arguments(scope_arguments),
          condition_arguments: canonical_arguments(condition_arguments)
        }

        if @permissions[role.to_s][model.to_s].include?(new_entry)
          logger.warn("[Writ] Duplicate permission registered: #{role}/#{model}/#{action}") unless @reloading
          return
        end

        @permissions[role.to_s][model.to_s] << new_entry
      end

      # Canonicalize an arguments hash for stable comparison/signatures:
      # deep-stringify keys and recursively sort keys at every level.
      # Array values are left in their original order (order can be semantic).
      # nil/empty becomes {}.
      # @param value [Hash, nil]
      # @return [Hash]
      def canonical_arguments(value)
        return {} if value.nil? || value.empty?

        value.keys.sort_by(&:to_s).each_with_object({}) do |key, acc|
          canonical_value = canonical_argument_value(value[key])
          # Drop empty-hash entries so "scope with no arguments" canonicalizes identically
          # whether expressed as an absent key or as `{ scope => {} }`.
          next if canonical_value.is_a?(Hash) && canonical_value.empty?

          acc[key.to_s] = canonical_value
        end
      end

      private def canonical_argument_value(value)
        case value
        when Hash
          value.keys.sort_by(&:to_s).to_h { |key| [key.to_s, canonical_argument_value(value[key])] }
        when Array
          value.map { |entry| canonical_argument_value(entry) }
        else
          value.deep_dup
        end
      end

      CRUD_FIELD_ACTIONS = %w[create read update delete].freeze

      # An omitted action is shorthand for four independent CRUD declarations.
      # @param model [String] Model name
      # @param role [String, Symbol] Role name
      # @param fields [Symbol, Array] :all, array of field names, or []
      def register_accessible_fields(model:, role:, fields:, action: nil)
        unless fields == :all || fields.is_a?(Array)
          raise ArgumentError, "fields must be :all or an Array, got #{fields.class}"
        end

        unless action.nil? || action.is_a?(String) || action.is_a?(Symbol)
          raise ArgumentError, 'Invalid field action'
        end
        if action && !action.to_s.match?(Writ::NAME_FORMAT)
          raise ArgumentError, 'Invalid field action'
        end
        actions = action.nil? ? CRUD_FIELD_ACTIONS : [action.to_s]
        current = @accessible_fields.dig(role.to_s, model.to_s) || {}
        if actions.any? { |name| current.key?(name) } && !@reloading
          logger.warn("[Writ] Overwriting accessible_fields for #{role}/#{model}")
        end

        # Replacing read fields must not overwrite independent update restrictions.
        @accessible_fields[role.to_s] ||= {}
        replacement = actions.to_h do |name|
          value = fields == :all ? nil : fields.map { |field| field.to_s.dup.freeze }.uniq.freeze
          [name, value]
        end
        @accessible_fields[role.to_s][model.to_s] = current.merge(replacement).freeze
      end

      # Register a role description
      # @param role [String, Symbol] Role name
      # @param description [String] Role description
      # NOTE: Descriptions can be set but not cleared through this API.
      # To clear a description, directly remove the key from @role_descriptions.
      def register_role_description(role:, description:)
        raise ArgumentError, "description must be a non-empty String, got #{description.inspect}" unless description.is_a?(String) && !description.empty?

        @role_descriptions[role.to_s] = description
      end

      # Get the stored description for a role, or nil if none is registered.
      # For a description with I18n fallback, use Configuration.role_description_with_fallback.
      # @param role_name [String, Symbol] Role name
      # @return [String, nil] Role description or nil
      def role_description(role_name)
        @role_descriptions[role_name.to_s]
      end

      # Check if a role has an explicit (non-I18n-default) description
      # @param role_name [String, Symbol] Role name
      # @return [Boolean]
      def role_description_explicit?(role_name)
        @role_descriptions.key?(role_name.to_s)
      end

      # Introspection: Get all scope metadata
      # @return [Hash] Deep copy of scope metadata hash
      def all_scope_metadata
        @scope_definitions.each_with_object({}) do |(model, scopes), result|
          result[model] = scopes.transform_values { |definition| { arguments: definition[:arguments] } }
        end.deep_dup
      end

      # Introspection: Get all permissions
      # @return [Hash] Deep copy of permissions hash
      def all_permissions
        @permissions.deep_dup
      end

      # Introspection: Get all accessible fields
      # @return [Hash] Deep copy of accessible fields hash
      def all_accessible_fields
        @accessible_fields.deep_dup
      end

      # Get a scope callable for a model and scope
      # @param model_name [String] The model name
      # @param scope_name [String, Symbol] The scope name
      # @return [Proc, nil] The scope callable or nil if not found
      def get_scope_callable(model_name:, scope_name:)
        @scope_definitions.dig(model_name.to_s, scope_name.to_s, :callable)
      end

      def get_scope_definition(model_name:, scope_name:)
        definition = @scope_definitions.dig(model_name.to_s, scope_name.to_s)
        definition && {
          callable: definition[:callable],
          arguments: definition[:arguments].deep_dup,
          matches: definition[:matches]
        }
      end

      def get_scope_matcher(model_name:, scope_name:)
        @scope_definitions.dig(model_name.to_s, scope_name.to_s, :matches)
      end

      def get_default_scope_matcher(model_name:)
        @default_scope_definitions.dig(model_name.to_s, :matches)
      end

      # Check if a scope callable is registered
      # @param model_name [String] The model name
      # @param scope_name [String, Symbol] The scope name
      # @return [Boolean] true if scope callable is registered
      def scope_callable_registered?(model_name:, scope_name:)
        !get_scope_callable(model_name: model_name, scope_name: scope_name).nil?
      end

      # Get all scope callables for a model
      # @param model_name [String] The model name
      # @return [Hash] Hash of scope_name => callable (defensive copy)
      def scope_callables_for(model_name:)
        (@scope_definitions[model_name.to_s] || {}).transform_values { |definition| definition[:callable] }
      end

      # Get all registered scope callables
      # @return [Hash] Nested hash of model_name => { scope_name => callable }
      def all_scope_callables
        @scope_definitions.transform_values do |scopes|
          scopes.transform_values { |definition| definition[:callable] }
        end
      end

      # Get list of models with registered scope callables
      # @return [Array<String>] Array of model names
      def models
        @scope_definitions.keys
      end

      # Get list of all models that have any model-specific configuration.
      # @return [Array<String>] Array of model names
      def all_configured_models
        model_set = Set.new
        model_set.merge(@scope_definitions.keys)
        model_set.merge(@default_scope_definitions.keys)
        @permissions.each_value { |role_models| model_set.merge(role_models.keys) }
        @accessible_fields.each_value { |role_models| model_set.merge(role_models.keys) }
        model_set.merge(@field_resolvers.keys.compact)
        model_set.merge(@creation_validators.keys.compact)
        model_set.merge(@update_validators.keys.compact)
        model_set.merge(@missing_default_scope_exemptions)
        model_set.to_a
      end

      # Get list of scope names for a model
      # @param model_name [String] The model name
      # @return [Array<String>] Array of scope names
      def scopes_for(model_name:)
        scope_callables_for(model_name: model_name).keys
      end

      def allow_missing_default_scope(model_name:)
        # This only exempts the boot-time default-scope check. It grants no access or scope bypass.
        @missing_default_scope_exemptions.add(model_name.to_s)
      end

      alias register_allow_missing_default_scope allow_missing_default_scope

      def clear!
        @reloading = true
        @scope_definitions.clear
        @default_scope_definitions.clear
        @condition_definitions.clear
        @permissions.clear
        @accessible_fields.clear
        @role_descriptions.clear
        @field_resolvers.clear
        @creation_validators.clear
        @update_validators.clear
        @missing_default_scope_exemptions.clear
      end

      def reload_complete!
        @reloading = false
        validate_references!
      end

      # If the block raises, validation is skipped to avoid masking the real error
      # with misleading "unregistered scope" errors from incomplete state.
      def reload
        clear!
        reload_failed = false
        yield
      rescue => e
        reload_failed = true
        raise
      ensure
        @reloading = false
        validate_references! unless reload_failed
      end

      # Validate that all scopes and conditions referenced in permissions are registered.
      # Called automatically by reload_complete! to catch typos at boot time.
      # @raise [ArgumentError] if any referenced scope or condition is not registered
      def validate_references!
        errors = []

        @permissions.each do |role, models|
          models.each do |model, perms|
            perms.each do |perm|
              perm[:scopes].each do |scope_name|
                unless @scope_definitions.dig(model, scope_name, :callable)
                  errors << "#{role}/#{model}/#{perm[:action]} references unregistered scope '#{scope_name}'"
                end
              end
              perm[:conditions].each do |condition_name|
                unless @condition_definitions.dig(condition_name, :callable)
                  errors << "#{role}/#{model}/#{perm[:action]} references unregistered condition '#{condition_name}'"
                end
              end
              validate_permission_arguments!(role, model, perm, errors)
            end
          end
        end

        if errors.any?
          raise Writ::ConfigurationError,
                "Permission validation failed. Check for typos in your permission definitions:\n  - #{errors.join("\n  - ")}"
        end

        permission_models = Set.new
        @permissions.each_value { |models| permission_models.merge(models.keys) }

        @accessible_fields.each do |role, models|
          models.each_key do |model|
            unless permission_models.include?(model)
              logger.warn(
                "[Writ] Role '#{role}' has accessible_fields for '#{model}' " \
                "but no permissions reference that model. Possible typo?"
              )
            end
          end
        end

        # A model scope without a default boundary can expose records before permission scopes narrow the relation.
        missing_default_scope_mode = Writ::Configuration.multi_tenant? ? Writ::Configuration.on_missing_default_scope : :skip
        @scope_definitions.each_key do |model_name|
          next if @default_scope_definitions.key?(model_name)
          next if @missing_default_scope_exemptions.include?(model_name)

          message = "Model '#{model_name}' has scopes but no default_scope. This may expose records across tenants."
          case missing_default_scope_mode
          when :raise
            errors << message
          when :warning
            logger.warn("[Writ] #{message}")
          end
        end

        if errors.any?
          raise Writ::ConfigurationError,
                "Permission validation failed. Check for typos in your permission definitions:\n  - #{errors.join("\n  - ")}"
        end
      end

      private

      def copy_validator_store(store)
        Hash.new { |hash, key| hash[key] = [] }.tap do |copy|
          store.each { |key, validators| copy[key] = validators.deep_dup }
        end
      end

      def reject_duplicate_declaration!(key, existing, replace, declaration_location)
        return if replace

        first_location = existing[:declaration_location] || 'unknown location'
        second_location = declaration_location || caller_location
        raise Writ::ConfigurationError,
              "Duplicate declaration for #{key}. First declaration: #{first_location}. Conflicting declaration: #{second_location}. Pass replace: true to replace it."
      end

      def caller_location
        location = caller_locations(2, 1).first
        "#{location.path}:#{location.lineno}"
      end

      def callable_source_location(callable)
        location = callable.respond_to?(:source_location) && callable.source_location
        return "#{location[0]}:#{location[1]}" if location

        caller_location
      end

      def validate_argument_key_collisions!(arguments, label)
        return if arguments.nil?

        unless arguments.is_a?(Hash)
          raise ArgumentError, "#{label.downcase} must be a Hash, got #{arguments.class}"
        end

        Writ::Logic::ArgumentValidator.validate_unique_normalized_keys!(arguments, label)

        arguments.each do |name, values|
          next unless values.is_a?(Hash)

          Writ::Logic::ArgumentValidator.validate_unique_normalized_keys!(
            values, "#{label} for '#{name}'"
          )
        end
      end

      def validate_callable!(callable, label)
        raise ArgumentError, "Block required for #{label}" unless callable.respond_to?(:call)
      end

      def validate_hook_signature!(callable, expected_keywords, label)
        return unless callable.respond_to?(:parameters)

        parameters = callable.parameters
        if parameters.any? { |kind, _| kind == :nokey }
          raise ArgumentError, "#{label} must accept the keywords #{expected_keywords.join(', ')}"
        end

        required_positionals = parameters.count { |kind, _| kind == :req }
        keyword_parameters = parameters.select { |kind, _| [:keyreq, :key].include?(kind) }
        accepts_keyword_rest = parameters.any? { |kind, _| kind == :keyrest }

        if keyword_parameters.any? || accepts_keyword_rest
          missing = expected_keywords - keyword_parameters.map(&:last)
          unexpected_required = keyword_parameters.select { |kind, _| kind == :keyreq }.map(&:last) - expected_keywords
          if (missing.any? && !accepts_keyword_rest) || unexpected_required.any?
            raise ArgumentError, "#{label} must accept the keywords #{expected_keywords.join(', ')}"
          end

          if required_positionals.positive?
            raise ArgumentError, "#{label} must accept hook keywords without required positional parameters"
          end

          return
        end

        optional_positionals = parameters.count { |kind, _| kind == :opt }
        accepts_positional_rest = parameters.any? { |kind, _| kind == :rest }
        return if callable.is_a?(Proc) && !callable.lambda? && required_positionals <= 1
        return if required_positionals <= 1 &&
                  (accepts_positional_rest || (required_positionals + optional_positionals).positive?)

        raise ArgumentError, "#{label} must accept hook keywords or one positional hash"
      end

      def register_validator(store, model_name, block, label)
        resolved = block
        validate_callable!(resolved, label)
        keywords = resolved.parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }
        validate_hook_signature!(resolved, keywords.include?(:errors) ? %i[context record errors] : %i[context record], label)
        key = model_name&.to_s
        store[key] << resolved
        resolved
      end

      def validators_for(store, model_name)
        global = store[nil] || []
        local = store[model_name.to_s] || []
        global + local
      end

      def logger
        Writ::Configuration.logger
      end

      def validate_permission_arguments!(role, model, perm, errors)
        [[:scopes, :scope_arguments], [:conditions, :condition_arguments]].each do |names_key, args_key|
          names = perm[names_key]
          arguments = perm[args_key] || {}
          (arguments.keys - names).each { |name| errors << "#{role}/#{model} has arguments for unattached #{name}" }
          names.each do |name|
            args = arguments[name] || {}
            schema = names_key == :scopes ? scope_arguments_schema(model_name: model, scope_name: name) : condition_arguments_schema(name: name)
            if schema.nil?
              errors << "#{role}/#{model}/#{perm[:action]} supplies arguments for '#{name}' which declares no argument schema" if args.any?
              next
            end
            argument_errors = Writ::Logic::ArgumentValidator.errors_for(schema: schema, arguments: args)
            # Conditions may be registered as bare or partial templates. Required values are
            # checked when a concrete permission is saved, while supplied values are validated
            # at boot so configuration mistakes fail early.
            if names_key == :conditions
              argument_errors = argument_errors.reject { |error| error.include?('missing required argument') }
            end
            argument_errors.each do |error|
              errors << "#{role}/#{model}/#{perm[:action]} #{name}: #{error}"
            end
          end
        end
      end

      def validate_callable_arity!(callable, scope_name, model_name, has_arguments: false)
        return unless callable.respond_to?(:arity) && !callable.is_a?(Symbol)

        arity = callable.arity

        if has_arguments
          # A parameterized callable must accept (context, args): arity 2, or a splat
          # that can receive a second positional (-1 = *a, -2 = a,*b, -3 = a,b,*c).
          return if accepts_positional_arguments?(callable, 2)

          raise ArgumentError,
                "Callable '#{scope_name}' for '#{model_name}' declares arguments and must accept " \
                "(context, args), got arity #{arity}"
        else
          dispatched_arguments = arity.zero? ? 0 : 1
          return if accepts_positional_arguments?(callable, dispatched_arguments)

          raise ArgumentError,
                "Callable '#{scope_name}' for '#{model_name}' must accept the dispatched positional arguments, got arity #{arity}"
        end
      end

      def accepts_positional_arguments?(callable, count)
        parameters = callable.parameters
        minimum = callable.arity >= 0 ? callable.arity : -(callable.arity + 1)
        maximum = parameters.count { |kind, _| [:req, :opt].include?(kind) }
        minimum <= count && (parameters.any? { |kind, _| kind == :rest } || maximum >= count) &&
          parameters.none? { |kind, _| [:keyreq, :key].include?(kind) }
      end

      def validate_matcher!(matcher, count)
        return if matcher.nil?
        unless matcher.respond_to?(:call) && matcher.respond_to?(:parameters) && accepts_positional_arguments?(matcher, count)
          raise ArgumentError, "Scope matcher must accept #{count} positional arguments"
        end
      end


    end
  end
end
