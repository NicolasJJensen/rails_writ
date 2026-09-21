# frozen_string_literal: true

module Writ
  module RakeHelpers
    module_function

    def format_header(title)
      "=" * 80 + "\n#{title.upcase}\n" + "=" * 80
    end

    def footer
      "=" * 80
    end

    # Render a list of scope/condition names, annotating any that carry arguments:
    #   in_locations(location_ids: [1, 2, 3])
    # Parens are omitted for entries with no arguments.
    def format_named_with_args(names, arguments)
      arguments ||= {}
      (names || []).map do |name|
        args = arguments[name] || arguments[name.to_sym]
        if args && !args.empty?
          "#{name}(#{args.map { |k, v| "#{k}: #{v.inspect}" }.join(', ')})"
        else
          name.to_s
        end
      end
    end

    # Render an argument schema as a compact "(args: name: type, ...)" suffix, or "" when none.
    def format_schema(schema)
      return "" if schema.nil? || schema.empty?

      parts = schema.map do |arg_name, spec|
        type = spec[:type] || spec[:type.to_s] || spec["type"]
        required = spec[:required] || spec["required"]
        "#{arg_name}: #{type}#{required ? '*' : ''}"
      end
      " (args: #{parts.join(', ')})"
    end

    def display_scopes(registry, options)
      metadata = registry.all_scope_metadata

      if metadata.empty?
        puts "\nNo scopes registered.\n"
        return
      end

      # Filter by model if specified
      if options[:model]
        metadata = metadata.select { |model, _| model.downcase.include?(options[:model].downcase) }
      end

      puts "\n" + format_header("Registered Scopes")

      # Entries are arrays of lines per logical item (not flat strings). This structure ensures
      # grep filters match/reject entire entries, and counts reflect logical items not line counts.
      model_groups = []
      metadata.sort.each do |model, scopes|
        group = { headers: ["\n#{model}:", "-" * 80], entries: [] }

        scopes.sort.each do |scope_name, data|
          has_filter = registry.scope_callable_registered?(model_name: model, scope_name: scope_name)
          filter_status = has_filter ? "✓" : "✗"
          description = I18n.t("writ.scopes.#{scope_name}", default: scope_name.humanize)
          schema = data.is_a?(Hash) ? (data[:arguments] || data["arguments"]) : nil
          args_suffix = format_schema(schema)

          if options[:expanded]
            entry = ["  [#{filter_status}] #{scope_name}", "      Description: #{description}"]
            entry << "      Arguments: #{schema.keys.join(', ')}" if schema && !schema.empty?
            group[:entries] << entry
          else
            group[:entries] << ["  [#{filter_status}] #{scope_name}#{args_suffix}: #{description}"]
          end
        end

        model_groups << group
      end

      # Apply grep filter — keep headers for groups that have matching entries
      if options[:grep]
        pattern = /#{Regexp.escape(options[:grep])}/i
        model_groups.each { |g| g[:entries].select! { |entry| entry.any? { |line| line.match?(pattern) } } }
        model_groups.reject! { |g| g[:entries].empty? }
      end

      output_lines = model_groups.flat_map { |g| g[:headers] + g[:entries].flatten }
      puts output_lines.join("\n")

      total_models = model_groups.count
      total_scopes = model_groups.sum { |g| g[:entries].count }
      puts "\n" + footer
      puts "Showing #{total_models} models, #{total_scopes} scopes"
      puts footer + "\n"
    end

    def display_permissions(registry, options)
      all_permissions = registry.all_permissions

      if all_permissions.empty?
        puts "\nNo permissions registered.\n"
        return
      end

      # Filter by role if specified
      if options[:role]
        all_permissions = all_permissions.select { |role, _| role.downcase.include?(options[:role].downcase) }
      end

      # Filter by model if specified
      if options[:model]
        all_permissions = all_permissions.transform_values do |models|
          models.select { |model, _| model.downcase.include?(options[:model].downcase) }
        end.reject { |_, models| models.empty? }
      end

      puts "\n" + format_header("Registered Permissions")

      # Two-level grouping: role_groups -> model_groups -> entries.
      # Each entry is an array of lines so grep and counts work per logical permission.
      role_groups = []
      all_permissions.sort.each do |role, models|
        role_group = { headers: ["\n#{role}:", "-" * 80], model_groups: [] }

        models.sort.each do |model, perms|
          model_group = { header: "  #{model}:", entries: [] }

          perms.each do |perm|
            if perm[:scopes]&.any?
              scopes_display = "(scopes: #{format_named_with_args(perm[:scopes], perm[:scope_arguments]).join(', ')})"
            else
              scopes_display = "(unrestricted)"
            end

            if options[:expanded]
              entry = ["    - #{perm[:action]}", "        #{scopes_display}"]
              if perm[:conditions]&.any?
                entry << "        (conditions: #{format_named_with_args(perm[:conditions], perm[:condition_arguments]).join(', ')})"
              end
              model_group[:entries] << entry
            else
              conditions_display = perm[:conditions]&.any? ? " [conditions: #{format_named_with_args(perm[:conditions], perm[:condition_arguments]).join(', ')}]" : ""
              model_group[:entries] << ["    - #{perm[:action]} #{scopes_display}#{conditions_display}"]
            end
          end

          role_group[:model_groups] << model_group
        end

        role_groups << role_group
      end

      # Apply grep filter — keep headers for groups that have matching entries
      if options[:grep]
        pattern = /#{Regexp.escape(options[:grep])}/i
        role_groups.each do |rg|
          rg[:model_groups].each { |mg| mg[:entries].select! { |entry| entry.any? { |line| line.match?(pattern) } } }
          rg[:model_groups].reject! { |mg| mg[:entries].empty? }
        end
        role_groups.reject! { |rg| rg[:model_groups].empty? }
      end

      output_lines = role_groups.flat_map do |rg|
        rg[:headers] + rg[:model_groups].flat_map { |mg| [mg[:header]] + mg[:entries].flatten }
      end
      puts output_lines.join("\n")

      total_roles = role_groups.count
      total_models = role_groups.sum { |rg| rg[:model_groups].count }
      total_permissions = role_groups.sum { |rg| rg[:model_groups].sum { |mg| mg[:entries].count } }
      puts "\n" + footer
      puts "Showing #{total_roles} roles, #{total_models} models, #{total_permissions} permissions"
      puts footer + "\n"
    end

    def display_conditions(registry, options)
      condition_names = registry.all_conditions

      if condition_names.empty?
        puts "\nNo conditions registered.\n"
        return
      end

      puts "\n" + format_header("Registered Conditions")

      # Cross-reference: which conditions are referenced by at least one permission?
      referenced_conditions = Set.new
      registry.all_permissions.each_value do |models|
        models.each_value do |perms|
          perms.each { |p| p[:conditions]&.each { |c| referenced_conditions << c } }
        end
      end

      # Each entry is an array of lines so grep and counts work per logical condition.
      entries = []
      condition_names.sort.each do |condition_name|
        in_use = referenced_conditions.include?(condition_name)
        status = in_use ? "✓" : "○"
        description = I18n.t("writ.conditions.#{condition_name}", default: condition_name.humanize)
        schema = registry.condition_arguments_schema(name: condition_name)
        args_suffix = format_schema(schema)

        if options[:expanded]
          entry = ["  [#{status}] #{condition_name}", "      Description: #{description}"]
          entry << "      Arguments: #{schema.keys.join(', ')}" if schema && !schema.empty?
          entries << entry
        else
          entries << ["  [#{status}] #{condition_name}#{args_suffix}: #{description}"]
        end
      end

      # Apply grep filter — match against any line in the entry
      if options[:grep]
        pattern = /#{Regexp.escape(options[:grep])}/i
        entries.select! { |entry| entry.any? { |line| line.match?(pattern) } }
      end

      puts entries.flatten.join("\n")

      puts "\n" + footer
      puts "Showing #{entries.count} conditions"
      puts footer + "\n"
    end
  end
end
