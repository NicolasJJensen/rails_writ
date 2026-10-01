# frozen_string_literal: true

module Writ
  module DSL
    class ScopeDSL
      attr_reader :validator

      def initialize(&block)
        instance_eval(&block)
        raise ArgumentError, 'Scope declaration requires a query block' unless @query
      end

      def query(&block)
        raise ArgumentError, 'Block required for query' unless block
        raise ArgumentError, 'Only one query block is allowed per scope' if @query
        validate_signature!(block, 0, 'query')
        @query = block
      end

      def validate(&block)
        raise ArgumentError, 'Block required for validate' unless block
        raise ArgumentError, 'Only one validate block is allowed per scope' if @validator
        validate_signature!(block, 2, 'validate')
        @validator = block
      end

      def query_callable
        query = @query
        ->(context = nil, arguments = nil) { self.class.invoke(query, context: context, arguments: arguments) }
      end

      def self.invoke(callback, *positionals, **keywords)
        parameters = callback.parameters
        unless parameters.any? { |kind, _| kind == :keyrest }
          names = parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }
          keywords = keywords.slice(*names)
        end
        callback.call(*positionals, **keywords)
      end

      private

      def validate_signature!(callback, positional_count, label)
        parameters = callback.parameters
        positionals = parameters.count { |kind, _| %i[req opt].include?(kind) }
        required = parameters.count { |kind, _| kind == :req }
        rest = parameters.any? { |kind, _| kind == :rest }
        unknown = parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) } - %i[context arguments]
        unless required <= positional_count && (rest || positionals == positional_count) && unknown.empty?
          raise ArgumentError, "#{label} must accept #{positional_count} positional arguments and optional context: and arguments: keywords"
        end
      end
    end
  end
end
