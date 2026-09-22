# Authorization reference

[Back to README](../README.md) · [Documentation index](README.md)

These APIs return decisions and relations. Your application enforces the decision at its controller, service, or job boundary.

## Entry points

```ruby
Access = Writ::Access
Access.grant_available?(context: actor, action: :read, model: Asset)
Access.filter(context: actor, action: :read, records: Asset.all).order(:name).limit(20)
```

## Saved-state authorization

Use `authorization` for saved-state decisions. It always returns an immutable result with
`allowed?`, `reason`, and `denied_grants`:

```ruby
Access.authorization(subject: Asset, action: :read, context: actor)
Access.authorization(subject: asset, action: :read, context: actor)
Access.authorization(subject: Asset.where(tenant_id: actor.tenant_id), action: :read, context: actor)
Access.authorization(subject: [asset_a, asset_b], action: :read, context: actor)
```

A model class checks grant availability. A persisted record checks saved SQL membership.
A relation or materialized collection is allowed only when every subject is authorized; an empty
collection is allowed. Use `filter` when you need a lazy relation instead of a decision result.

## Proposed-state validation

Use `validation` for local proposed-state checks. It accepts a new or changed record, or an array
of records, and evaluates proposed matchers and applicable creation or update validators without
saved-state membership queries:

```ruby
Access.validation(subject: Asset.new(tenant_id: actor.tenant_id), action: :create, context: actor)
Access.validation(subject: asset, action: :update, context: actor)
```

An empty array returns an allowed result. `validation` requires new records for `:create` and
persisted records for `:update`; persisted records can also use read, delete, or custom actions
to evaluate local matchers. Create and update validators apply only to their matching actions.
It rejects model classes and ActiveRecord relations. It does not replace the host's
transaction, locking, freshness, save, or nested-record authorization policy. The immutable result
exposes `allowed?`, a stable symbol `reason`, and per-grant `denied_grants`. Each denial has
`permission_id`, `reason`, and `failed_conditions`. The host decides how to present or log that data.

## Denial details

Other denial reasons include `:no_permission_source`, `:condition_error`, `:missing_condition`,
`:condition_arguments_invalid`, and `:scope_arguments_invalid`. A successful result has an empty
`denied_grants` array. The gem returns decision data; host applications own messages, translations,
and response formatting.

## Query semantics

* `grant_available?` checks grant conditions but intentionally ignores record scopes. Use for potential navigation/action availability, never to authorize a particular record.
* `filter` returns a lazy ActiveRecord relation. Scopes within a grant intersect; grants across roles form a union. Default policy scopes constrain every grant. No explicit deny overrides a separate valid grant.
* An authorization result for a collection requires **all records before pagination** to be permitted. An empty collection passes. ORDER, LIMIT, and OFFSET are stripped. Filter first, then paginate.
* Query projections and caller restrictions survive filtering and permission annotations. Scope projections are ignored when computing membership. Grouped relations are rejected.
* SQL filtering expects the model's normal table qualifier. For derived queries, use `Asset.from(inner_relation, :assets)` (substitute the real model table name). Arbitrary `FROM` aliases such as `assets AS other_assets` are not supported; adapt the query in the host before filtering.
* `potential_permissions` is potential grant metadata; it does not evaluate scopes or conditions.

See [Creating and updating records](record-changes.md) for proposed-state validation and [Field permissions](fields.md) for field access.
