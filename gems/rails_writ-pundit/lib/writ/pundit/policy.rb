# frozen_string_literal: true

module Writ
  module Pundit
    class Policy
      include PolicyHelpers

      attr_reader :context, :record

      def initialize(context, record)
        @context = context
        @record = record
      end

      def index?
        permitted?(:read)
      end

      def show?
        permitted?(:read)
      end

      def read?
        permitted?(:read)
      end

      def new?
        permitted?(:create)
      end

      def create?
        permitted?(:create)
      end

      def edit?
        permitted?(:update)
      end

      def update?
        permitted?(:update)
      end

      def destroy?
        permitted?(:delete)
      end

      def delete?
        permitted?(:delete)
      end

      def permitted_attributes_for_create
        input_attributes(:create)
      end

      def permitted_attributes_for_update
        input_attributes(:update)
      end

      class Scope
        attr_reader :scope, :context

        def initialize(context, scope)
          @scope = scope
          @context = context
        end

        def resolve
          Writ::Access.filter(context: context, action: :read, records: scope)
        end
      end

      private

      def input_attributes(action)
        fields = Writ::Access.input_fields(context: context, record: record, action: action)
        model = record.is_a?(Class) ? record : record.class
        (fields == :all ? model.attribute_names : fields).map(&:to_sym)
      end

      def permitted?(action)
        # Proposed-state validation stays explicit so a Pundit check does not also validate pending changes.
        Writ::Access.authorization(context: context, action: action, subject: record).allowed?
      end
    end
  end
end
