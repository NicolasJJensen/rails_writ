# frozen_string_literal: true

module Writ
  module Pundit
    module Authorization
      ATTRIBUTES_NOT_PROVIDED = Object.new.freeze
      private_constant :ATTRIBUTES_NOT_PROVIDED

      protected

      def authorize_proposed!(record, action: nil, attributes: ATTRIBUTES_NOT_PROVIDED)
        action ||= record.new_record? ? :create : :update
        options = { subject: record, action: action, context: pundit_user }
        options[:attributes] = attributes unless attributes.equal?(ATTRIBUTES_NOT_PROVIDED)
        proposal = Writ::Access.propose(**options)
        record = proposal.record
        result = proposal.result
        result.apply_errors_to(record)
        return record if result.allowed?

        query = :"#{action}?"
        if %i[proposed_scope_mismatch forbidden_fields validator_rejected invalid_sti_type].include?(result.reason)
          raise ProposedAuthorizationError.new(record: record, result: result, query: query)
        end

        raise ::Pundit::NotAuthorizedError.new(record: record, query: query)
      end
    end
  end
end

# Extending the Pundit module also reaches controllers that included it before this adapter loaded.
::Pundit::Authorization.include(Writ::Pundit::Authorization)
