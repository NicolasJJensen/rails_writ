# frozen_string_literal: true

module Writ
  class Access
    GrantDenial = Struct.new(:permission_id, :reason, :failed_conditions, keyword_init: true) do
      def initialize(permission_id:, reason:, failed_conditions: [])
        super(permission_id: permission_id, reason: reason.to_sym, failed_conditions: failed_conditions.map(&:to_sym).freeze)
        freeze
      end
    end

    CheckResult = Struct.new(:allowed, :reason, :denied_grants, keyword_init: true) do
      def initialize(allowed:, reason:, denied_grants: [])
        super(allowed: !!allowed, reason: reason.to_sym, denied_grants: denied_grants.freeze)
        freeze
      end

      def allowed?
        allowed
      end
    end
  end
end
