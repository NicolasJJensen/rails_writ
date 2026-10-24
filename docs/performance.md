# Performance and instrumentation

[Back to README](../README.md)

Use batching when rendering collections, and measure query construction separately from SQL execution. Use `Writ::Access` for the core API; the adapter uses the same query implementation.

## Batch field access

```ruby
records = Writ::Access.filter(context: actor, action: :read, records: Asset).limit(50).to_a
fields_by_record = Writ::Access.fields_for_many(context: actor, action: :read, records: records)
# { asset => ["name", ...] }; each value can also be :all or [].
```

The input must contain persisted records belonging to one registered authorization hierarchy
or resolving to one explicit authorization model, with a loaded single-column primary key.
Mixed Van and Truck records are supported when they share inherited Vehicle rules. Unrelated
models and composite primary keys are not supported by batch field decisions.
The result maps each record to its effective fields; denied records receive `[]`.
An empty batch returns `{}`.

Both tenancy modes use the same batching API. In multi-tenant mode pass a context restricted to one selected tenant; do not combine tenant contexts within a batch.

The gem groups membership checks by contributing role and concrete record class instead of
issuing a query for every record. Inherited grants and subtype boundaries participate in those
checks. Resolvers still run once per authorized record. Measure query counts for the application's
role and subtype mix; adding distinct subtype rules can add query branches and groups.

Keep batches bounded and group heterogeneous data when that query shape matters. Keep
context stable during a batch; there is no result cache across calls. Field queries do not
themselves serialize or permit input parameters.

## Instrumentation

Register a subscriber in an initializer:

```ruby
ActiveSupport::Notifications.subscribe("permission.filter.writ") do |event|
  Rails.logger.info(
    event: event.name,
    reason: event.payload[:reason],
    duration_ms: event.payload[:duration_ms],
    timing: event.payload[:timing]
  )
end
```

Subscribe to `permission.filter.writ` using ActiveSupport::Notifications. Filter events include grant counts and a reason (`no_permission_source`, `no_grants`, `no_valid_grants`, `filtered`, or `error`). Error events contain the exception class, not its potentially sensitive message.

Filter `duration_ms` uses a monotonic clock and measures **query construction**, including loading grant metadata and executing Ruby conditions, not eventual record-query execution. `timing: 'query_construction'` makes that distinction explicit. Use ActiveRecord SQL notifications for database execution timing. Event delivery does not load the returned relation or count matching records. Scope/condition argument metadata is assembled only with a subscriber and contains stored arguments; treat it as potentially sensitive in your logger.

## Profiling

From the source checkout, run against the local test database:

```sh
bundle exec ruby benchmarks/permission_queries.rb
```

The script measures construction and execution separately across 1, 10, and 50 overlapping
grants, including association scopes. It also measures batch field decisions and SQL query
counts, checks returned IDs and effective fields (including denied records), emits PostgreSQL
JSON query plans, and rolls back its fixtures.

| Option | Default | Meaning |
|---|---|---|
| `RECORDS` | 1000 | Number of assets |
| `REPEATS` | 5 | Measurements per grant count |
| `LOCATIONS` | 50 | Available locations |
| `OVERLAP_WIDTH` | 3 | Consecutive locations allowed by each grant |
| `ASSOCIATION_CARDINALITY` | 3 | Industry associations per asset, controlling join fanout |
| `ROLES` | 5 | Maximum roles sharing the grants |
| `BATCH_SIZE` | 50 | Maximum records per field batch |
| `PLAN_DIR` | `/tmp/writ_plans` | PostgreSQL plan output directory |

Run separately from the test suite. Results are local measurements, not production latency
guarantees. Compare plans and correctness before changing the authorization query strategy.
