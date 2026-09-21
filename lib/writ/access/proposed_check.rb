# frozen_string_literal: true

module Writ
  class Access
    module ProposedCheck
      private

      def proposed_grant_matches?(context, record, permission, model, authorization_model, normalized_arguments: nil)
        registry = Configuration.registry
        default_matcher = registry.get_default_scope_matcher(model_name: authorization_model.name)
        if registry.default_scope_registered?(model_name: authorization_model.name) || model.default_scopes.any?
          return false unless proposed_matcher_matches?(context, record, default_matcher, 'default_scope', model)
        end

        permission.permission_scopes.all? do |attachment|
          name = attachment.scope.name
          matcher = registry.get_scope_matcher(model_name: authorization_model.name, scope_name: name)
          args = ScopeEvaluator.resolve_arguments(registry, authorization_model.name, name, attachment,
                                                  normalized_arguments: normalized_arguments)
          proposed_matcher_matches?(context, record, matcher, name, model, args)
        end
      end

      def preflight_proposed_matchers!(permissions, model, authorization_model)
        registry = Configuration.registry
        default_required = registry.default_scope_registered?(model_name: authorization_model.name) || model.default_scopes.any?
        if default_required && !registry.get_default_scope_matcher(model_name: authorization_model.name)
          missing_matcher!(model, 'default_scope')
        end
        permissions.each do |permission|
          permission.permission_scopes.each do |attachment|
            name = attachment.scope.name
            next if registry.get_scope_matcher(model_name: authorization_model.name, scope_name: name)

            missing_matcher!(model, name)
          end
        end
      end

      def proposed_matcher_matches?(context, record, matcher, name, model, args = nil)
        unless matcher
          return true unless Configuration.on_missing_matcher == :raise

          missing_matcher!(model, name)
        end

        args.nil? ? !!matcher.call(context, record) : !!matcher.call(context, record, args.deep_dup)
      end

      def run_action_validators(context, record, action, model)
        registry = Configuration.registry
        method = action.to_s == 'create' ? :creation_validators_for : :update_validators_for
        validators = registry.public_send(method, model_name: model.name)
        result = true
        validators.each { |validator| result = !!validator.call(context: context, record: record) && result }
        result
      end

      def missing_matcher!(model, name)
        message = "Define a matches: matcher for #{model.name}/#{name} before checking proposed access"
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
