# frozen_string_literal: true

module Writ
  class Access
    module Inheritance
      private

      def membership_models(model)
        return [model] if Configuration.custom_authorization_model_resolver?
        return [model] unless model.column_names.include?(model.inheritance_column)

        configured = Configuration.registry.all_configured_models.filter_map do |name|
          candidate = name.safe_constantize
          candidate if candidate.is_a?(Class) && candidate < ActiveRecord::Base && candidate <= model &&
                       candidate.base_class == model.base_class && candidate.table_name == model.table_name
        end
        models = ([model] + configured).uniq
        (models + model.descendants.select { |child| child.base_class == model.base_class && child.table_name == model.table_name }).uniq
      end

      def metadata_models(model)
        names = if Configuration.custom_authorization_model_resolver?
          [model.name]
        else
          Configuration.registry.model_lineage(model_name: model.name)
        end
        names.map(&:constantize)
      end

      def prepare_membership_permissions(context, action, model, **options)
        models = membership_models(model).flat_map { |candidate| Configuration.authorization_models_for(candidate) }.uniq
        prepare_permissions(context, action, Configuration.authorization_model_for(model),
                            authorization_models: models, **options)
      end

      def permission_membership(context, model, authorization_model, prepared, permissions: prepared.valid)
        pk = primary_key!(model)
        outer = ScopeEvaluator.strip_ordering_and_limits(model.all)
        partitions = membership_models(model)
        partitions.reduce(outer.none) do |membership, candidate|
          metadata_model = candidate == model ? authorization_model : Configuration.authorization_model_for(candidate)
          names = metadata_models(metadata_model).map(&:name)
          applicable = permissions.select { |permission| names.include?(permission.model) }
          next membership if applicable.empty?

          base = ScopeEvaluator.default_scoped_records(context, candidate, metadata_model)
          # Partition by exact type: unknown/unregistered subclasses cannot fall through
          # an ancestor branch and bypass their own authorization rules.
          if !Configuration.custom_authorization_model_resolver? && candidate.column_names.include?(candidate.inheritance_column)
            types = candidate == candidate.base_class ? [nil, '', candidate.sti_name] : [candidate.sti_name]
            base = base.where(candidate.inheritance_column => types)
          end
          grant_base = ScopeEvaluator.strip_ordering_and_limits(candidate.all)
          allowed = applicable.reduce(base.none) do |branches, permission|
            branch = ScopeEvaluator.filter_records_by_context_and_permission(
              context, candidate, permission, authorization_model: metadata_model,
              normalized_arguments: prepared.normalized_arguments, base: grant_base, apply_default: false
            )
            branches.or(base.where(pk => branch.reselect(candidate.arel_table[pk])))
          end
          if partitions.one?
            allowed
          else
            membership.or(outer.where(pk => allowed.reselect(candidate.arel_table[pk])))
          end
        end
      end
    end
  end
end
