# frozen_string_literal: true

module Writ
  # Diagnostics and introspection utilities for the Writ registry.
  # Separated from Registry to keep the registry as a pure in-memory data store
  # without upward dependencies on Configuration or the database.
  class Diagnostics
    def initialize(registry = Configuration.registry)
      @registry = registry
    end

    # Get statistics about registered scope callables
    # @return [Hash] Statistics including counts
    def statistics
      scope_callables = @registry.all_scope_callables
      total_scope_callables = scope_callables.values.sum { |scopes| scopes.size }

      stats = {
        total_models: scope_callables.size,
        total_scope_callables: total_scope_callables,
        models: {}
      }

      scope_callables.each do |model_name, scopes|
        stats[:models][model_name] = {
          scope_callable_count: scopes.size,
          scopes: scopes.keys
        }
      end

      stats
    end

    # Pretty print the registry for debugging
    # @return [String] Formatted string representation
    def inspect_registry
      scope_callables = @registry.all_scope_callables
      output = ["Scope Callable Registry:"]
      output << "=" * 60

      scope_callables.each do |model_name, scopes|
        output << "\n#{model_name}:"
        scopes.each do |scope_name, callable|
          callable_type = callable.is_a?(Proc) ? "Proc" : callable.class.name
          output << "  - #{scope_name} (#{callable_type})"
        end
      end

      conditions = @registry.all_conditions
      if conditions.any?
        output << "\nConditions:"
        conditions.each do |name|
          output << "  - #{name}"
        end
      end

      output << "\n" + "=" * 60
      total_scope_callables = scope_callables.values.sum { |s| s.size }
      output << "Total: #{total_scope_callables} scope callables across #{scope_callables.size} models"

      output.join("\n")
    end
  end
end
