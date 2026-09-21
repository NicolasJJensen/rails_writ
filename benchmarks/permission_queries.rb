# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'
abort 'This benchmark only runs against the test environment' unless ENV['RAILS_ENV'] == 'test'
require_relative '../spec/dummy/config/environment'
require 'factory_bot'
require 'json'
require 'fileutils'

FactoryBot.find_definitions
record_count = Integer(ENV.fetch('RECORDS', '1000'))
repeats = Integer(ENV.fetch('REPEATS', '5'))
location_count = Integer(ENV.fetch('LOCATIONS', '50'))
association_cardinality = Integer(ENV.fetch('ASSOCIATION_CARDINALITY', '3'))
overlap_width = Integer(ENV.fetch('OVERLAP_WIDTH', '3'))
role_count = Integer(ENV.fetch('ROLES', '5'))
batch_size = Integer(ENV.fetch('BATCH_SIZE', '50'))
abort 'RECORDS and REPEATS must be positive' unless record_count.positive? && repeats.positive?
abort 'LOCATIONS, ASSOCIATION_CARDINALITY, OVERLAP_WIDTH, ROLES and BATCH_SIZE must be positive' unless
  [location_count, association_cardinality, overlap_width, role_count, batch_size].all?(&:positive?)
overlap_width = [overlap_width, location_count].min
plan_dir = ENV.fetch('PLAN_DIR', '/tmp/writ_plans')
FileUtils.mkdir_p(plan_dir)
configuration = Writ::Configuration
original_registry = configuration.registry
median = ->(values) { values.sort[values.length / 2].round(3) }

def measure_sql
  statement_count = 0
  subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
    payload = args.last
    statement_count += 1 unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
  end
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = yield
  elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
  [result, statement_count, elapsed_ms]
ensure
  ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
end

begin
  ActiveRecord::Base.transaction do
    organisation = FactoryBot.create(:organisation)
    locations = FactoryBot.create_list(:location, location_count, organisation: organisation)
    industries = FactoryBot.create_list(:service_industry, association_cardinality)
    now = Time.current
    ids = Asset.insert_all!(Array.new(record_count) do |index|
      { name: "Benchmark #{index}", organisation_id: organisation.id,
        location_id: locations[index % locations.length].id, status: 0,
        archived: false, created_at: now, updated_at: now }
    end).rows.flatten
    asset_location_ids = ids.each_with_index.to_h { |id, index| [id, locations[index % locations.length].id] }
    connection = Asset.connection
    # The fixture IDs come from this transaction, never from existing host records.
    industries.each do |industry|
      connection.execute("INSERT INTO assets_service_industries (asset_id, service_industry_id) " \
                         "SELECT id, #{connection.quote(industry.id)} FROM assets WHERE id IN (#{ids.join(',')})")
    end
    configuration.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    configuration.configure do
      default_scope(model: Asset) { Asset.where(organisation_id: organisation.id) }
      scope(:benchmark_locations, model: Asset, arguments: { ids: { type: :array, required: true } }) do |_context, args|
        Asset.where(location_id: args[:ids])
      end
      scope(:benchmark_industry, model: Asset) do
        Asset.joins(:service_industries).where(service_industries: { id: industries.map(&:id) })
      end
    end

    [1, 10, 50].each do |grant_count|
      roles = Array.new([grant_count, role_count].min) do |index|
        organisation.roles.create!(name: "Benchmark #{grant_count}/#{index}",
                                   accessible_fields: { 'Asset' => { 'read' => (index.even? ? ['name'] : ['description']) } })
      end
      grant_locations = grant_count.times.map do |index|
        # Adjacent grants overlap independently of the association join fanout.
        locations.rotate(index % locations.length).first(overlap_width)
      end
      grant_count.times do |index|
        roles[index % roles.length].permissions.create!(
          model: 'Asset', action: 'read',
          scopes: [{ benchmark_locations: { ids: grant_locations[index].map(&:id) } }, :benchmark_industry]
        )
      end
      actor = Struct.new(:permissions, :roles).new(Permission.where(role_id: roles.map(&:id)), Role.where(id: roles.map(&:id)))
      expected_ids = ids.select do |id|
        location_id = asset_location_ids.fetch(id)
        grant_locations.any? { |grant| grant.any? { |location| location.id == location_id } }
      end.sort
      expected_fields = ids.index_with do |id|
        matching_roles = grant_locations.each_index.select do |index|
          grant_locations[index].any? { |location| location.id == asset_location_ids.fetch(id) }
        end
        matching_roles.flat_map { |index| (index % roles.length).even? ? ['name'] : ['description'] }.uniq.sort
      end
      construction_ms = []
      execution_ms = []
      filter_construction_query_counts = []
      filter_execution_query_counts = []
      fields_ms = []
      fields_query_counts = []
      relation = nil
      ActiveRecord::Base.uncached do
        repeats.times do
          relation, query_count, elapsed_ms = measure_sql do
            Writ::Access.filter(context: actor, action: :read, records: Asset)
          end
          construction_ms << elapsed_ms
          filter_construction_query_counts << query_count
          actual, query_count, elapsed_ms = measure_sql { relation.pluck(:id).sort }
          execution_ms << elapsed_ms
          filter_execution_query_counts << query_count
          raise 'Benchmark authorization returned incorrect records' unless actual == expected_ids

          records = Asset.where(id: ids).order(:id).limit(batch_size).to_a
          fields, query_count, elapsed_ms = measure_sql do
            Writ::Access.fields_for_many(context: actor, action: :read, records: records)
          end
          fields_ms << elapsed_ms
          fields_query_counts << query_count
          raise 'Batch field authorization omitted records' unless fields.keys == records
          fields.each do |record, values|
            raise 'Batch field authorization returned incorrect fields' unless values.sort == expected_fields.fetch(record.id)
          end
        end
      end
      raw_plan = connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{relation.reselect(:id).to_sql}")
      plan = raw_plan.is_a?(String) ? JSON.parse(raw_plan) : raw_plan
      File.write(File.join(plan_dir, "grants_#{grant_count}_associations_#{association_cardinality}_overlap_#{overlap_width}.json"), JSON.pretty_generate(plan))
      puts JSON.generate(
        rails: ActiveRecord::VERSION::STRING, records: record_count, locations: location_count,
        association_cardinality: association_cardinality, overlap_width: overlap_width,
        batch_size: [batch_size, record_count].min, roles: roles.length, grants: grant_count,
        construction_median_ms: median.call(construction_ms), execution_median_ms: median.call(execution_ms),
        filter_construction_query_count_median: median.call(filter_construction_query_counts),
        filter_execution_query_count_median: median.call(filter_execution_query_counts),
        fields_for_many_median_ms: median.call(fields_ms),
        fields_query_count_median: median.call(fields_query_counts),
        postgres_planning_ms: plan.first['Planning Time'], postgres_execution_ms: plan.first['Execution Time']
      )
    end
    raise ActiveRecord::Rollback
  end
ensure
  configuration.instance_variable_set(:@registry, original_registry)
  Current.reset
end
