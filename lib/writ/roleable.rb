# frozen_string_literal: true

module Writ
  module Roleable
    extend ActiveSupport::Concern

    included do
      class_attribute :writ_roleable_configuration,
                      instance_accessor: false,
                      instance_predicate: false
    end

    class_methods do
      # @param scoping_model [Boolean] When true, this model owns roles (e.g., Organisation)
      #   and generates default permissions on creation. When false, this model is assigned
      #   roles (e.g., User) and only gets the association without triggering generation.
      # @param auto_generate [Boolean] Controls whether default permissions are generated
      #   on create. Defaults to the value of scoping_model for backwards compatibility.
      #   Set to false to disable auto-generation even for scoping models.
      def as_roleable(scoping_model: false, auto_generate: scoping_model)
        configuration = { scoping_model: scoping_model, auto_generate: auto_generate }.freeze
        if writ_roleable_configuration
          # Changing these options would leave previously installed associations
          # and callbacks in place, so repeated configuration must agree.
          previous = writ_roleable_configuration
          return if previous == configuration

          raise ArgumentError,
                "Writ roleable configuration already set to #{previous.inspect}; " \
                "cannot reconfigure as #{configuration.inspect}"
        end
        self.writ_roleable_configuration = configuration

        role_class_name = Writ::Configuration.role_class_name

        if scoping_model
          has_many :roles, class_name: role_class_name, dependent: :destroy
          belongs_to :default_user_role, class_name: role_class_name,
                     foreign_key: 'default_role_id', optional: true
        else
          has_and_belongs_to_many :roles, class_name: role_class_name
        end

        has_many :permissions, through: :roles

        if auto_generate
          after_create { Writ::Generator.generate_default_permissions(self) }
        end
      end
    end
  end
end
