# frozen_string_literal: true

module Writ
  module Pundit
    module Authorization
      ATTRIBUTES_NOT_PROVIDED = Object.new.freeze
      private_constant :ATTRIBUTES_NOT_PROVIDED

      protected

      def authorize_proposed!(record, action: nil, attributes: ATTRIBUTES_NOT_PROVIDED)
        action ||= record.new_record? ? :create : :update
        submitted_fields = if attributes.equal?(ATTRIBUTES_NOT_PROVIDED)
          record.changed_attribute_names_to_save
        else
          record.assign_attributes(attributes)
          attributes.keys
        end
        result = Writ::Access.validation(subject: record, action: action, context: pundit_user,
                                         submitted_fields: submitted_fields)
        result.apply_errors_to(record)
        return record if result.allowed?

        query = :"#{action}?"
        if %i[proposed_scope_mismatch forbidden_fields validator_rejected].include?(result.reason)
          raise ProposedAuthorizationError.new(record: record, result: result, query: query)
        end

        raise ::Pundit::NotAuthorizedError.new(record: record, query: query)
      end
    end
  end
end

# Extending the Pundit module also reaches controllers that included it before this adapter loaded.
::Pundit::Authorization.include(Writ::Pundit::Authorization)
