# frozen_string_literal: true

module Writ
  class Access
    module ProposedCheck
      private

      def proposed_grant_errors(context, record, permission, model, authorization_model, normalized_arguments: nil)
        registry = Configuration.registry
        errors = ActiveModel::Errors.new(record)
        defaults = ScopeEvaluator.default_scope_owners(authorization_model)
        defaults = [authorization_model.name] if defaults.empty? && model.default_scopes.any?
        defaults.each do |owner|
          evaluate_proposed_scope(context, record, errors,
                                  registry.get_default_scope_matcher(model_name: owner),
                                  registry.get_default_scope_validator(model_name: owner),
                                  'default_scope', model)
        end

        permission.permission_scopes.each do |attachment|
          name = attachment.scope.name
          owner = attachment.scope.model
          args = ScopeEvaluator.resolve_arguments(registry, owner, name, attachment,
                                                  normalized_arguments: normalized_arguments)
          evaluate_proposed_scope(context, record, errors,
                                  registry.get_scope_matcher(model_name: owner, scope_name: name),
                                  registry.get_scope_validator(model_name: owner, scope_name: name),
                                  name, model, args)
        end
        errors
      end

      def preflight_proposed_matchers!(permissions, model, authorization_model)
        registry = Configuration.registry
        defaults = ScopeEvaluator.default_scope_owners(authorization_model)
        defaults = [authorization_model.name] if defaults.empty? && model.default_scopes.any?
        defaults.each do |owner|
          unless registry.get_default_scope_matcher(model_name: owner) || registry.get_default_scope_validator(model_name: owner)
            missing_matcher!(owner.constantize, 'default_scope')
          end
        end
        permissions.each do |permission|
          permission.permission_scopes.each do |attachment|
            name = attachment.scope.name
            owner = attachment.scope.model
            next if registry.get_scope_matcher(model_name: owner, scope_name: name) ||
                    registry.get_scope_validator(model_name: owner, scope_name: name)

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
        Array(model).flat_map do |candidate|
          metadata = Configuration.authorization_model_for(candidate)
          registry.public_send(method, model_name: metadata.name,
                                include_inherited: !Configuration.custom_authorization_model_resolver?)
        end.uniq.each do |validator|
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
