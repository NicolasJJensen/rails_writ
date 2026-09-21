# frozen_string_literal: true

require 'active_support/core_ext/hash/indifferent_access'

module Writ
  module Logic
    # Validates scope/condition argument values against a declared schema, and
    # validates the schema definitions themselves.
    #
    # Schema format (v1):
    #   {
    #     department_ids: { type: :array, required: true, default: [], max_length: 500 }
    #   }
    #
    # Supported keys per argument:
    #   - type:       one of ALLOWED_TYPES (required)
    #   - required:   boolean (default false)
    #   - default:    static value applied when the argument is omitted
    #   - max_length: integer cap for :array and :string values
    #
    # Shared by scopes and conditions (the schema and value shapes are identical).
    module ArgumentValidator
      module_function

      ALLOWED_TYPES = %i[array string integer boolean].freeze

      VALID_SCHEMA_KEYS = %i[type required default max_length].freeze

      # Validate the shape of a schema definition at registration time.
      # @raise [ArgumentError] if the schema is malformed
      def validate_schema!(schema, label)
        return if schema.nil?

        unless schema.is_a?(Hash)
          raise ArgumentError, "Argument schema for #{label} must be a Hash, got #{schema.class}"
        end

        normalized_names = schema.keys.map(&:to_s)
        duplicate_names = normalized_names.tally.select { |_name, count| count > 1 }.keys
        if duplicate_names.any?
          raise ArgumentError,
                "Argument schema for #{label} has duplicate normalized key(s): #{duplicate_names.join(', ')}"
        end

        schema.each do |arg_name, spec|
          unless spec.is_a?(Hash)
            raise ArgumentError, "Argument '#{arg_name}' schema for #{label} must be a Hash, got #{spec.class}"
          end

          validate_unique_normalized_keys!(spec, "Argument '#{arg_name}' schema for #{label}")

          unknown = spec.keys.map(&:to_sym) - VALID_SCHEMA_KEYS
          if unknown.any?
            raise ArgumentError,
                  "Argument '#{arg_name}' schema for #{label} has unknown key(s): #{unknown.join(', ')}. " \
                  "Valid keys: #{VALID_SCHEMA_KEYS.join(', ')}"
          end

          type = spec[:type] || spec['type']
          unless ALLOWED_TYPES.include?(type&.to_sym)
            raise ArgumentError,
                  "Argument '#{arg_name}' schema for #{label} has invalid type #{type.inspect}. " \
                  "Allowed types: #{ALLOWED_TYPES.join(', ')}"
          end

          required = spec.key?(:required) ? spec[:required] : spec['required']
          if !required.nil? && ![true, false].include?(required)
            raise ArgumentError, "Argument '#{arg_name}' required for #{label} must be a boolean"
          end

          max_length = spec[:max_length] || spec['max_length']
          if max_length && !max_length.is_a?(Integer)
            raise ArgumentError, "Argument '#{arg_name}' max_length for #{label} must be an Integer"
          end
          if max_length && max_length.negative?
            raise ArgumentError, "Argument '#{arg_name}' max_length for #{label} must be non-negative"
          end

          if spec.key?(:default) || spec.key?('default')
            default = spec.key?(:default) ? spec[:default] : spec['default']
            type_errors = type_errors_for(arg_name, default, type&.to_sym, max_length)
            unless type_errors.empty?
              raise ArgumentError, "Argument '#{arg_name}' default for #{label} is invalid: #{type_errors.join('; ')}"
            end
          end
        end
      end

      # Reject Ruby symbol/string key pairs that would collapse during JSON-style
      # normalization. JSON objects themselves cannot contain this distinction.
      def duplicate_normalized_keys(value)
        return [] unless value.is_a?(Hash)

        value.keys.map(&:to_s).tally.filter_map { |key, count| key if count > 1 }
      end

      def validate_unique_normalized_keys!(value, label)
        duplicates = duplicate_normalized_keys(value)
        return if duplicates.empty?

        raise ArgumentError,
              "#{label} has duplicate normalized key(s): #{duplicates.join(', ')}"
      end

      # Validate provided argument values against a schema and return a normalized
      # HashWithIndifferentAccess with defaults applied.
      # @raise [InvalidArgumentsError] listing every problem found
      def validate!(schema:, arguments:, label:)
        errors = []
        normalized = normalize(schema: schema, arguments: arguments, errors: errors)
        unless errors.empty?
          raise Writ::InvalidArgumentsError,
                "Invalid arguments for #{label}:\n  - #{errors.join("\n  - ")}"
        end
        normalized
      end

      # Non-raising variant: returns an array of error strings (empty when valid).
      def errors_for(schema:, arguments:)
        errors = []
        normalize(schema: schema, arguments: arguments, errors: errors)
        errors
      end

      # Build the normalized argument hash, accumulating problems into +errors+.
      # Order: reject unknown keys -> merge defaults -> type/max_length checks -> required checks.
      def normalize(schema:, arguments:, errors:)
        schema = (schema || {}).transform_keys(&:to_s)
        unless arguments.nil? || arguments.is_a?(Hash)
          errors << 'arguments must be a hash (JSON object)'
          return ActiveSupport::HashWithIndifferentAccess.new
        end
        duplicate_normalized_keys(arguments).each do |key|
          errors << "#{key} has duplicate normalized key(s): #{key}"
        end
        provided = (arguments || {}).transform_keys(&:to_s)
        result = {}

        unknown = provided.keys - schema.keys
        unknown.each { |key| errors << "unknown argument '#{key}'" }

        schema.each do |arg_name, raw_spec|
          spec = raw_spec.transform_keys(&:to_sym)
          has_value = provided.key?(arg_name)
          value = provided[arg_name]

          if !has_value && spec.key?(:default)
            value = spec[:default]
            has_value = true
          end

          if !has_value
            errors << "missing required argument '#{arg_name}'" if spec[:required]
            next
          end

          type_errors_for(arg_name, value, spec[:type]&.to_sym, spec[:max_length]).each { |e| errors << e }

          result[arg_name] = value.deep_dup
        end

        ActiveSupport::HashWithIndifferentAccess.new(result)
      end

      # Returns an array of type/length error strings for a single value (empty when valid).
      def type_errors_for(arg_name, value, type, max_length)
        errors = []
        case type
        when :array
          if value.is_a?(Array)
            if max_length && value.length > max_length
              errors << "argument '#{arg_name}' exceeds max_length #{max_length}"
            end
          else
            errors << "argument '#{arg_name}' must be an array"
          end
        when :string
          if value.is_a?(String)
            if max_length && value.length > max_length
              errors << "argument '#{arg_name}' exceeds max_length #{max_length}"
            end
          else
            errors << "argument '#{arg_name}' must be a string"
          end
        when :integer
          errors << "argument '#{arg_name}' must be an integer" unless value.is_a?(Integer)
        when :boolean
          errors << "argument '#{arg_name}' must be a boolean" unless [true, false].include?(value)
        end
        errors
      end
    end
  end
end
