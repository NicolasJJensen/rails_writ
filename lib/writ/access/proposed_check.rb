# frozen_string_literal: true

module Writ
  class Access
    module ProposedCheck
      private

      def proposed_grant_errors(context, record, permission, model, authorization_model, normalized_arguments: nil)
        registry = Configuration.registry
        errors = ActiveModel::Errors.new(record)
        if registry.default_scope_registered?(model_name: authorization_model.name) || model.default_scopes.any?
          evaluate_proposed_scope(context, record, errors,
                                  registry.get_default_scope_matcher(model_name: authorization_model.name),
                                  registry.get_default_scope_validator(model_name: authorization_model.name),
                                  'default_scope', model)
        end

        permission.permission_scopes.each do |attachment|
          name = attachment.scope.name
          args = ScopeEvaluator.resolve_arguments(registry, authorization_model.name, name, attachment,
                                                  normalized_arguments: normalized_arguments)
          evaluate_proposed_scope(context, record, errors,
                                  registry.get_scope_matcher(model_name: authorization_model.name, scope_name: name),
                                  registry.get_scope_validator(model_name: authorization_model.name, scope_name: name),
                                  name, model, args)
        end
        errors
      end

      def preflight_proposed_matchers!(permissions, model, authorization_model)
        registry = Configuration.registry
        default_required = registry.default_scope_registered?(model_name: authorization_model.name) || model.default_scopes.any?
        if default_required && !registry.get_default_scope_matcher(model_name: authorization_model.name) &&
           !registry.get_default_scope_validator(model_name: authorization_model.name)
          missing_matcher!(model, 'default_scope')
        end
        permissions.each do |permission|
          permission.permission_scopes.each do |attachment|
            name = attachment.scope.name
            next if registry.get_scope_matcher(model_name: authorization_model.name, scope_name: name) ||
                    registry.get_scope_validator(model_name: authorization_model.name, scope_name: name)

            missing_matcher!(model, name)
          end
        end
      end

      def evaluate_proposed_scope(context, record, errors, matcher, validator, name, model, args = nil)
        scope_errors = ActiveModel::Errors.new(record)
        if validator
          DSL::ScopeDSL.invoke(validator, record, scope_errors, context: context, arguments: args&.deep_dup)
        end
        if matcher
          matched = args.nil? ? matcher.call(context, record) : matcher.call(context, record, args.deep_dup)
          scope_errors.add(:base, :not_permitted, message: 'is not permitted') unless matched
        elsif !validator && Configuration.on_missing_matcher == :raise
          missing_matcher!(model, name)
        end
        scope_errors.each { |error| errors.import(error) }
      end

      def run_action_validators(context, record, action, model)
        registry = Configuration.registry
        method = action.to_s == 'create' ? :creation_validators_for : :update_validators_for
        errors = ActiveModel::Errors.new(record)
        registry.public_send(method, model_name: model.name).each do |validator|
          accepts_errors = validator.parameters.any? { |kind, name| %i[key keyreq].include?(kind) && name == :errors }
          if accepts_errors
            validator_errors = ActiveModel::Errors.new(record)
            DSL::ScopeDSL.invoke(validator, context: context, record: record, errors: validator_errors)
            validator_errors.each { |error| errors.import(error) }
          elsif !validator.call(context: context, record: record)
            errors.add(:base, :not_permitted, message: 'is not permitted')
          end
        end
        errors
      end

      def missing_matcher!(model, name)
        message = "Define a validate block or matches: matcher for #{model.name}/#{name} before checking proposed access"
        case Configuration.on_missing_matcher
        when :raise
          raise ConfigurationError, message
        when :warning
          Configuration.logger.warn("[Writ] #{message}")
        end
      end
    end
  end
end
