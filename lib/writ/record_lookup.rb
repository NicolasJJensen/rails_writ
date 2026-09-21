# frozen_string_literal: true

module Writ
  module RecordLookup
    module_function

    def find_or_create!(relation, attributes, &block)
      relation.transaction(requires_new: true) do
        relation.find_or_create_by!(attributes, &block)
      end
    rescue ActiveRecord::RecordNotUnique
      # The savepoint must finish before querying PostgreSQL after a constraint failure.
      relation.find_by(attributes) || raise
    rescue ActiveRecord::RecordInvalid => error
      details = error.record.errors.details
      uniqueness_only = details.any? && details.all? do |attribute, errors|
        attributes.key?(attribute) && errors.all? { |detail| detail[:error] == :taken }
      end
      raise unless uniqueness_only
      relation.find_by(attributes) || raise
    end
  end
end
