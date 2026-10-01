require 'optparse'
require 'writ/rake_helpers'

namespace :writ do
  desc "Display permissions (use -h for help)"
  task :permissions => :environment do
    # Consume ARGV arguments after -- to prevent Rake from treating them as tasks
    if (separator_idx = ARGV.index('--'))
      ARGV[(separator_idx + 1)..].each { |arg| task arg.to_sym do ; end }
    end

    options = {
      grep: nil,
      model: nil,
      role: nil,
      expanded: false,
      show_scopes: false,
      show_conditions: false
    }

    parser = OptionParser.new do |opts|
      opts.banner = "Usage: rake writ:permissions [options]\n\n"
      opts.separator "Note: Use -- before flags to separate them from Rake arguments."
      opts.separator ""
      opts.separator "Examples:"
      opts.separator "  rake writ:permissions -- -c Asset"
      opts.separator "  rake writ:permissions -- -g read"
      opts.separator "  rake writ:permissions -- -R Admin"
      opts.separator "  rake writ:permissions -- -c Asset -E"
      opts.separator "  rake writ:permissions -- -s"
      opts.separator "  rake writ:stats"
      opts.separator "\nOptions:"

      opts.on("-c", "--controller MODEL", "Filter by model name (like rails routes -c)") do |model|
        options[:model] = model
      end

      opts.on("-g PATTERN", "Grep output for PATTERN (like rails routes -g)") do |pattern|
        options[:grep] = pattern
      end

      opts.on("-R", "--role ROLE", "Filter by role name") do |role|
        options[:role] = role
      end

      opts.on("-E", "--expanded", "Show expanded view") do
        options[:expanded] = true
      end

      opts.on("-s", "--scopes", "Show scopes instead of permissions") do
        options[:show_scopes] = true
      end

      opts.on("--conditions", "Show conditions instead of permissions") do
        options[:show_conditions] = true
      end

      opts.on("-h", "--help", "Show this help message") do
        options[:help] = true
      end
    end

    args = if (separator_idx = ARGV.index('--'))
      ARGV[(separator_idx + 1)..]
    else
      []
    end
    parser.parse!(args)

    if options[:help]
      puts parser
      next
    end

    registry = Writ::Configuration.registry

    if options[:show_scopes]
      Writ::RakeHelpers.display_scopes(registry, options)
    elsif options[:show_conditions]
      Writ::RakeHelpers.display_conditions(registry, options)
    else
      Writ::RakeHelpers.display_permissions(registry, options)
    end
  end

  desc "Generate default permissions (ORG=id or ID=id, MODEL=ClassName optional, MODELS=A,B to limit to specific models)"
  task generate: :environment do
    record_id = ENV['ORG'] || ENV['ID']

    models_filter = ENV['MODELS']&.split(',')&.map(&:strip)&.reject(&:empty?)

    unless record_id
      puts "\n" + Writ::RakeHelpers.format_header("Generating Global Permissions")

      Writ::Generator.generate_default_permissions(models: models_filter)

      puts "Generated global permissions"
      puts "Limited to models: #{models_filter.join(', ')}" if models_filter
      puts Writ::RakeHelpers.footer + "\n"
      next
    end

    model_class = begin
      model_name = ENV['MODEL'] || Writ::Configuration.scoping_model
      unless model_name
        abort("\nMODEL is required when using ID=. Set MODEL=ClassName or configure scoping_model.\n")
      end
      model_name.constantize.tap do |candidate|
        if Writ::Configuration.multi_tenant?
          configured_name = Writ::Configuration.scoping_model
          if configured_name.present?
            configured_model = configured_name.to_s.constantize
            unless candidate == configured_model
              abort("\n#{candidate.name} is not the configured tenant/scoping model " \
                    "#{configured_model.name}. Pass the tenant ID with MODEL=#{configured_model.name}.\n")
            end
          else
            roleable_configuration = candidate.respond_to?(:writ_roleable_configuration) &&
                                     candidate.writ_roleable_configuration
            unless roleable_configuration && roleable_configuration[:scoping_model]
              abort("\n#{candidate.name} is not a supported tenant/scoping model. " \
                    "Configure scoping_model or mark the model with as_roleable(scoping_model: true).\n")
            end
          end
        end
      end
    rescue NameError
      abort("\nModel '#{model_name}' not found. Check the class name and ensure it is defined.\n")
    end

    record = model_class.find_by(model_class.primary_key => record_id)

    abort("\n#{model_class.name} with ID #{record_id} not found\n") unless record

    unless record.respond_to?(:roles)
      abort("\n#{model_class.name} does not have a roles association. " \
            "Ensure the model includes Writ::Roleable.\n")
    end

    puts "\n" + Writ::RakeHelpers.format_header("Generating Permissions: #{record.respond_to?(:name) ? record.name : record.id}")

    before_roles = record.roles.count
    before_permissions = Writ::Configuration.permission_class.where(role: record.roles).count

    Writ::Generator.generate_default_permissions(record, models: models_filter)

    after_roles = record.roles.count
    after_permissions = Writ::Configuration.permission_class.where(role: record.roles).count

    puts "Created #{[after_roles - before_roles, 0].max} new roles"
    puts "Created #{[after_permissions - before_permissions, 0].max} new permissions"
    puts "Total roles: #{after_roles}"
    puts "Total permissions: #{after_permissions}"
    puts Writ::RakeHelpers.footer + "\n"
  end

  desc "List all registered scope callables"
  task list_scopes: :environment do
    puts "Registered Writ Scope Callables"
    puts "=" * 60
    puts

    registry = Writ::Configuration.registry
    puts Writ::Diagnostics.new(registry).inspect_registry
  end

  desc "Show statistics"
  task stats: :environment do
    puts "Writ Statistics"
    puts "=" * 60
    puts

    registry = Writ::Configuration.registry
    stats = Writ::Diagnostics.new(registry).statistics

    puts "Total Models: #{stats[:total_models]}"
    puts "Total Scope Callables: #{stats[:total_scope_callables]}"
    puts

    puts "Breakdown by Model:"
    stats[:models].each do |model_name, data|
      puts "  #{model_name}:"
      puts "    Scope callables: #{data[:scope_callable_count]}"
      puts "    Scopes: #{data[:scopes].join(', ')}"
    end
  end

  desc "Remove stale permissions and accessible fields no longer in DSL config"
  task cleanup: :environment do
    puts "Writ Cleanup"
    puts "=" * 60

    registry = Writ::Configuration.registry
    stale_items = Writ::Generator.stale_items(registry)

    perm_stale_count = stale_items.count { |i| i[:type] == :permission }
    af_stale_count = stale_items.count { |i| i[:type] == :accessible_field }
    scope_stale_count = stale_items.count { |i| i[:type] == :scope }
    condition_stale_count = stale_items.count { |i| i[:type] == :condition }

    puts "\nFound #{perm_stale_count} stale permission(s)"
    puts "Found #{af_stale_count} stale accessible field(s)"
    puts "Found #{scope_stale_count} stale scope(s)"
    puts "Found #{condition_stale_count} stale condition(s)"

    total = stale_items.size
    if total == 0
      puts "\nNo stale data found. Everything is in sync with the DSL config."
      next
    end

    puts "\nStale items to remove (#{total} total):"
    stale_items.each do |item|
      puts "  [#{item[:type]}] #{item[:label]}"
    end

    if ENV['DRY_RUN'] == '1' || ENV['DRY_RUN']&.downcase == 'true'
      puts "\nDRY RUN — no changes made. Re-run without DRY_RUN=1 to apply."
      next
    end

    unless ENV['CONFIRM'] == '1'
      puts "\nTo apply these changes, re-run with CONFIRM=1:"
      puts "  rake writ:cleanup CONFIRM=1"
      puts "\nOr preview with DRY_RUN=1 first."
      next
    end

    puts "\nProceeding with removal..."
    removed_count = Writ::Generator.cleanup!(
      registry: registry,
      stale_items: stale_items,
      on_skip: ->(item, message) { puts "  #{message}: #{item[:label]}" }
    )

    puts "\nRemoved #{removed_count} of #{total} stale item(s)."
  end
end
