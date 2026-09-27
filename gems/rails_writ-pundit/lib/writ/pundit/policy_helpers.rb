# frozen_string_literal: true

module Writ
  module Pundit
    module PolicyHelpers
      extend ActiveSupport::Concern

      class_methods do
        def inherited(child)
          super
          child.instance_variable_set(:@ap_local_permissions_declared, false)
        end

        # Get the model class from the policy name
        # Example: AssetPolicy => Asset
        def policy_model
          @policy_model ||= begin
            model_name = name.gsub(/Policy$/, '')
            model_name.constantize
          rescue NameError
            raise NameError,
                  "#{name} could not resolve model '#{model_name}'. " \
                  "Either define the model or override `policy_model` in #{name}."
          end
        end

        # Define a default scope for this policy's model
        # Default scopes are always applied before permission scopes
        # Only one default scope per model
        # @param block [Proc] Scope implementation; can accept 0 or 1 parameters
        # @example Zero parameters (uses Current context directly)
        #   default_scope do
        #     Asset.where(organisation: Current.organisation)
        #   end
        # @example One parameter (receives the context object)
        #   default_scope do |context|
        #     Asset.where(organisation: context.organisation)
        #   end
        def default_scope(matches: nil, replace: false, &block)
          configuration_dsl.default_scope(model: policy_model, matches: matches, replace: replace,
                                          declaration_location: caller_location, &block)
        end

        # Define a scope for this policy's model
        # @param name [Symbol] Scope name
        # @param block [Proc] Scope implementation; can accept 0 or 1 parameters
        # @example Zero parameters (uses Current context directly)
        #   scope :service_industry do
        #     Asset.joins(:service_industries)
        #          .where(service_industries: { id: Current.user.service_industries })
        #   end
        # @example One parameter (receives the context object)
        #   scope :service_industry do |context|
        #     Asset.joins(:service_industries)
        #          .where(service_industries: { id: context.service_industries })
        #   end
        def scope(name, arguments: {}, matches: nil, replace: false, &block)
          configuration_dsl.scope(name, model: policy_model, arguments: arguments, matches: matches, replace: replace,
                                  declaration_location: caller_location, &block)
        end

        def field_resolver(include_global: false, append: false, replace: false, &block)
          configuration_dsl.field_resolver(model: policy_model, include_global: include_global,
                                           append: append, replace: replace, &block)
        end

        def creation_validator(&block)
          configuration_dsl.creation_validator(model: policy_model, &block)
        end

        def update_validator(&block)
          configuration_dsl.update_validator(model: policy_model, &block)
        end

        # Define a condition for use in permissions
        # @param name [Symbol] Condition name
        # @param block [Proc] Condition implementation; can accept 0 or 1 parameters
        # @example
        #   condition :business_hours do |context|
        #     (9..17).cover?(Time.current.hour)
        #   end
        def condition(name, arguments: {}, replace: false, &block)
          configuration_dsl.condition(name, arguments: arguments, replace: replace, declaration_location: caller_location, &block)
        end

        def allow_missing_default_scope
          # Shared models can omit a default scope without disabling the check for other models.
          configuration_dsl.allow_missing_default_scope(model: policy_model)
        end

        def with_conditions(*entries, &block)
          configuration_dsl.with_conditions(*entries, &block)
        end

        def requires_conditions(*entries)
          raise ArgumentError, 'requires_conditions must be declared before permissions' if @ap_local_permissions_declared
          names, arguments = configuration_dsl.normalize_condition_entries(entries)
          inherited_names, inherited_arguments = inherited_condition_requirements
          merged_names, merged_arguments = configuration_dsl.merge_condition_entries(
            inherited_names, inherited_arguments, names, arguments
          )
          @ap_required_conditions = [merged_names, merged_arguments]
        end

        # Define permissions for a specific role with a block
        # Automatically sets the model based on the policy name
        # @param role_name [Symbol, String] Role name
        # @param description [String, nil] Optional role description (defaults to I18n lookup)
        # @param block [Proc] Block containing permission definitions
        # @example
        #   role :Technician do
        #     permission :read, scopes: [:service_industry]
        #     permission :create, scopes: [:service_industry]
        #     accessible_fields :all
        #   end
        #
        #   role :Admin, description: "Full access administrator" do
        #     permission :read
        #     permission :create
        #   end
        # Per-thread stack for role context (thread-safe, supports nesting)
        def role_stack
          Thread.current[:"__ap_role_stack_#{name}__"] ||= []
        end

        def role(role_name, description: nil, &block)
          raise ArgumentError, "role_name is required" if role_name.blank?

          role_stack.push({ role: role_name, model: policy_model })
          pushed = true

          if description
            Writ::Configuration.register_role_description(
              role: role_name,
              description: description
            )
          end

          instance_eval(&block) if block_given?
        ensure
          role_stack.pop if pushed
        end

        # Define a permission for the current role and model
        # Must be called within a role block
        # @param action [Symbol] Action name (:read, :create, :update, :delete)
        # @param scopes [Array<Symbol>] Array of scope names (default: [])
        # @param conditions [Array<Symbol>] Array of condition names (default: [])
        # Note: defaults differ from ConfigurationDSL (which uses nil to inherit from with_options).
        # PolicyHelpers always defaults to empty arrays since role blocks don't use with_options.
        # @example
        #   permission :read, scopes: [:service_industry]
        #   permission :update, scopes: [:current_location], conditions: [:business_hours]
        def permission(action, scopes: [], conditions: [])
          ctx = current_role_context
          @ap_local_permissions_declared = true
          required_names, required_arguments = inherited_condition_requirements
          lexical_names, lexical_arguments = configuration_dsl.current_conditions
          required_names, required_arguments = configuration_dsl.merge_condition_entries(
            required_names, required_arguments, lexical_names, lexical_arguments
          )
          explicit_names, explicit_arguments = configuration_dsl.normalize_condition_entries(
            conditions.is_a?(Array) ? conditions : [conditions]
          )
          names, arguments = configuration_dsl.merge_condition_entries(
            required_names, required_arguments, explicit_names, explicit_arguments
          )
          configuration_dsl.permission_with_entries(
            action,
            model: ctx[:model],
            role: ctx[:role],
            scopes: scopes,
            condition_names: names,
            condition_arguments: arguments
          )
        end

        # Define accessible fields for the current role and model
        # Must be called within a role block
        # @param fields [Symbol, Array] :all for all fields, [] for no field access, or array of field names
        # @example
        #   accessible_fields :all
        #   accessible_fields [:name, :email]
        #   accessible_fields []  # No field access
        def accessible_fields(fields, action: nil)
          ctx = current_role_context
          configuration_dsl.accessible_fields(fields, model: ctx[:model], role: ctx[:role], action: action)
        end

        def current_role_context
          raise ArgumentError, "must be called within a role block" if role_stack.empty?
          role_stack.last
        end

        def inherited_condition_requirements
          names = []
          arguments = {}
          ancestors.reverse_each do |ancestor|
            next unless ancestor.respond_to?(:instance_variable_get)
            local = ancestor.instance_variable_get(:@ap_required_conditions)
            next unless local
            names, arguments = configuration_dsl.merge_condition_entries(names, arguments, local[0], local[1])
          end
          [names, arguments]
        end

        private

        def caller_location
          location = caller_locations(2, 1).first
          "#{location.path}:#{location.lineno}"
        end

        def configuration_dsl
          @configuration_dsl ||= Writ::DSL::ConfigurationDSL.new(
            Writ::Configuration
          ).freeze
        end
      end
    end
  end
end
