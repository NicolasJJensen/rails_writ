# frozen_string_literal: true

require 'rails/generators'

module Writ
  module Pundit
    module Generators
      class PolicyGenerator < Rails::Generators::NamedBase
        source_root File.expand_path('templates', __dir__)

        desc "Creates a policy file for a model with role and permission definitions"

        class_option :roles, type: :array, required: true,
                     desc: "Role names to scaffold (e.g. --roles Admin Technician)"
        class_option :actions, type: :array, default: %w[read create update delete],
                     desc: "Permission actions to scaffold (defaults to CRUD)"

        INHERITED_PREDICATE_NAMES = [
          *Object.public_instance_methods,
          *Object.protected_instance_methods,
          *Object.private_instance_methods,
          *BasicObject.public_instance_methods,
          *BasicObject.protected_instance_methods,
          *BasicObject.private_instance_methods,
          *Kernel.public_instance_methods,
          *Kernel.protected_instance_methods,
          *Kernel.private_instance_methods
        ].filter_map { |name| name.to_s.delete_suffix('?') if name.to_s.end_with?('?') }.uniq.freeze

        def initialize(*args)
          super
          invalid = action_names.reject { |action| action.to_s.match?(Writ::NAME_FORMAT) }
          return raise_invalid_action(invalid.first) unless invalid.empty?

          reserved = action_names.map(&:to_s) & reserved_action_names
          return if reserved.empty?

          raise ArgumentError,
                "Reserved policy action '#{reserved.first}' conflicts with the generated CRUD predicate mapping; " \
                'use read, create, update, delete, or another custom action'
        end

        def create_policy
          template 'policy.rb.tt', "app/policies/#{file_path}_policy.rb"
        end

        private

        def raise_invalid_action(action)
          raise ArgumentError,
                "Invalid action '#{action}'. Actions must be lowercase, start with a letter, " \
                'and contain only letters, numbers, and underscores'
        end

        def role_names
          options[:roles]
        end

        def action_names
          options[:actions]
        end

        def custom_action_names
          action_names.map(&:to_s).reject do |action|
            %w[index show new create edit update destroy read delete].include?(action)
          end.uniq
        end

        def reserved_action_names
          %w[index show new edit destroy permitted] + INHERITED_PREDICATE_NAMES
        end
      end
    end
  end
end
