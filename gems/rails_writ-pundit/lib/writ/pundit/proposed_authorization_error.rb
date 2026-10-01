# frozen_string_literal: true

module Writ
  module Pundit
    class ProposedAuthorizationError < ::Pundit::NotAuthorizedError
      attr_reader :result

      def initialize(record:, result:, query:)
        @result = result
        super(record: record, query: query, message: 'Proposed attributes are not permitted')
      end
    end
  end
end
