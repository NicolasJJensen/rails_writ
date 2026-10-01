# frozen_string_literal: true

module Writ
  class Access
    ErrorSnapshot = Struct.new(:attribute, :type, :options, keyword_init: true) do
      def initialize(attribute:, type:, options: {})
        super(attribute: attribute.to_sym, type: immutable(type), options: immutable(options))
        freeze
      end

      private

      def immutable(value)
        copy = case value
        when Module then value
        when Hash then value.to_h { |key, entry| [immutable(key), immutable(entry)] }
        when Array then value.map { |entry| immutable(entry) }
        when Set then value.class.new(value.map { |entry| immutable(entry) })
        when Struct
          value.dup.tap { |duplicate| value.each_pair { |key, entry| duplicate[key] = immutable(entry) } }
        when Range then Range.new(immutable(value.begin), immutable(value.end), value.exclude_end?)
        else value.deep_dup
        end
        # Classes and other identity values cannot be detached; never freeze host-owned objects.
        copy.freeze unless copy.equal?(value)
        copy
      end
    end

    def self.error_snapshots(errors)
      errors.map do |error|
        error.is_a?(ErrorSnapshot) ? error : ErrorSnapshot.new(attribute: error.attribute, type: error.type, options: error.options)
      end.freeze
    end

    def self.generic_errors
      [ErrorSnapshot.new(attribute: :base, type: :not_permitted, options: { message: 'is not permitted' })].freeze
    end

    GrantDenial = Struct.new(:permission_id, :reason, :failed_conditions, :errors, keyword_init: true) do
      def initialize(permission_id:, reason:, failed_conditions: [], errors: [])
        super(permission_id: permission_id, reason: reason.to_sym, failed_conditions: failed_conditions.map(&:to_sym).freeze,
              errors: Access.error_snapshots(errors))
        freeze
      end
    end

    CheckResult = Struct.new(:allowed, :reason, :denied_grants, :errors, keyword_init: true) do
      def initialize(allowed:, reason:, denied_grants: [], errors: nil)
        errors ||= allowed ? [] : Access.generic_errors
        super(allowed: !!allowed, reason: reason.to_sym, denied_grants: denied_grants.dup.freeze,
              errors: Access.error_snapshots(errors))
        freeze
      end

      def allowed?
        allowed
      end

      def apply_errors_to(record)
        previous = record.instance_variable_get(:@writ_applied_errors) || []
        record.errors.objects.delete_if { |error| previous.any? { |owned| owned.equal?(error) } }
        applied = errors.map { |error| record.errors.add(error.attribute, error.type, **error.options.deep_dup) }
        record.instance_variable_set(:@writ_applied_errors, applied)
        record
      end
    end
  end
end
