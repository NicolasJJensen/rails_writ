# API and advanced configuration

[README](../README.md) covers installation, both tenancy modes, ordinary configuration, and complete read/write flows. This reference covers less common behavior. Core examples belong in `config/writ/*.rb` and work without Pundit.

## Decision inputs

| API and subject | Behavior |
|---|---|
| `authorization` with a model class | Checks grant availability and conditions, not record scopes. |
| `authorization` with a saved record | Checks saved SQL membership. |
| `authorization` with a relation or array | Every record must be allowed. Empty collections pass. |
| `authorization` with a new record and `:create` | Checks create-grant availability; does not validate proposed attributes. |
| `propose` with a new or persisted record | Assigns optional attributes, resolves STI changes, and returns the proposed record with its field/state decision. Infers create/update unless `action:` is supplied. |
| `validation` with a new record and `:create` | Checks conditions, scope validators, and creation validators. |
| `validation` with a persisted record and `:update` | Checks proposed attributes and update validators. Primary keys must be unchanged. |
| `filter` with a model or relation | Returns a lazy relation containing allowed records. |

`propose` returns `Writ::Access::ProposalResult`, with `record` and `result` accessors. Keep its record before saving; STI conversion can return a different instance. It does not save or apply errors automatically. Omitted `attributes:` uses dirty tracking; explicit attributes check every supplied key, including unchanged values. A type conversion also checks the inheritance column, even when it was not supplied in `attributes:`. The adapter uses the same proposal operation and applies its final errors.

`validation` also accepts arrays, with an empty array allowed. It rejects model classes and relations. Its record must already have the correct STI class, and direct type changes during update are rejected; use `propose` for conversion. Persisted records may use read/delete/custom actions for local scope checks; lifecycle validators apply only to their matching create/update actions.

`grant_available?` ignores record scopes. Use it for potential navigation/action availability, never as permission to access a particular record. `potential_permissions` and `declared_fields` are metadata, not record authorization.

## Results and errors

```ruby
result = Writ::Access.authorization(subject: asset, action: :read, context: context)
if result.allowed?
  # Return the permitted data.
else
  Rails.logger.info(reason: result.reason, denied_grants: result.denied_grants)
end
```

Results are immutable. Each denied grant exposes `permission_id`, `reason`, `failed_conditions`, and immutable `errors` snapshots. Proposed results expose final `errors`; `apply_errors_to(record)` imports them without removing unrelated errors. Success has an empty `denied_grants` array.

Reasons include `:no_permission_source`, `:no_grants`, `:scope_mismatch`, `:proposed_scope_mismatch`, `:forbidden_fields`, `:invalid_sti_type`, `:validator_rejected`, `:condition_error`, `:missing_condition`, `:condition_arguments_invalid`, and `:scope_arguments_invalid`. A configuration error can raise instead of returning a denial, according to the failure modes below.

Applications own messages, translations, and HTTP responses. Avoid logging sensitive context or stored arguments indiscriminately.

## SQL composition

- Scopes within a grant intersect; separate valid grants combine. A default scope constrains every grant.
- Collection authorization strips `ORDER`, `LIMIT`, and `OFFSET`. Filter first, then paginate the filtered relation.
- Filtering preserves caller restrictions and projections. Scope projections are ignored for membership checks.
- Grouped relations and composite primary keys are unsupported.
- Use the model's normal table qualifier. Arbitrary `FROM` aliases are unsupported.

For a derived query, alias it back to the real table name:

```ruby
inner = Asset.where(archived: false)
records = Asset.from(inner, :assets)
Writ::Access.filter(context: context, action: :read, records: records)
```

These contracts are the same in both tenancy modes; multi-tenant scopes must additionally enforce the record boundary.

## Custom models, namespaces, and keys

Use `--roleable-model` for the actor model and `--model-namespace` for generated authorization models. Create the actor model first.

Single tenant:

```sh
bin/rails generate writ:install --roleable-model=Account --model-namespace=Authorization
```

Multi-tenant, with an existing `Organisation` model:

```sh
bin/rails generate writ:install --roleable-model=Account --model-namespace=Authorization \
  --multi-tenant --scoping-model=Organisation
```

For the adapter, substitute `writ:pundit:install`; the same options apply. The initializer configures all six generated authorization classes. If writing your own context for namespaced models, use `Authorization::Permission` instead of `Permission`.

Generators infer key columns and types from existing model tables. When those tables are not available yet, specify the keys explicitly:

```sh
bin/rails generate writ:install --roleable-model=Account \
  --roleable-primary-key=account_uuid --roleable-primary-key-type=uuid
```

In tenant mode, add the corresponding tenant options:

```sh
bin/rails generate writ:install --multi-tenant --roleable-model=Account \
  --roleable-primary-key=account_uuid --roleable-primary-key-type=uuid \
  --scoping-primary-key=organisation_uuid --scoping-primary-key-type=uuid
```

Supported types are `bigint`, `integer`, `uuid`, and `string`. Set `self.primary_key` on the host models for nonstandard columns. These options do not modify host primary keys. Composite keys are rejected before generation.

Loaded model table names are respected; unloaded models use demodulized conventional table names. Generated models inherit `ApplicationRecord`. Customize that superclass and associations when your application differs. All authorization models must share a database connection for atomic generation and cleanup.

## Parameterized rules

The README explains [scope arguments](../README.md#scope-arguments), including equivalent query and proposed-record checks. Conditions accept an `arguments:` schema and a positional `(context, arguments)` block:

```ruby
Writ.configure do
  condition :allowed_hours, arguments: { hours: { type: :array, required: true } } do |_user, arguments|
    arguments.fetch(:hours).include?(Time.current.hour)
  end

  permission :read, model: Asset, role: :Member,
                   conditions: [{ allowed_hours: { hours: [9, 10, 11] } }]
end
```

Conditions apply identically to global and tenant roles. Tenant record boundaries still belong in default scopes. For arguments supplied during tenant generation, see [Permission management](permission-management.md#tenant-specific-condition-arguments).

Scope `query` callbacks accept optional `context:` and `arguments:` keywords. Scope `validate` callbacks receive `(record, errors)` plus either keyword when needed. Declare only the inputs you use. The high-level declaration block contains these callbacks; it does not execute a database query during registration.

Low-level `register_scope` and `register_default_scope` retain positional SQL callbacks and optional boolean `matches:` callbacks. Explicit high-level `matches:` declarations also remain supported. Use the named `query` / `validate` form for new definitions.

## Registration and replacement

A duplicate scope, condition, or default scope raises with declaration locations. Use `replace: true` only when overriding intentionally:

```ruby
Writ.configure do
  scope :owned, model: Asset, replace: true do
    query { |context:| Asset.where(owner_id: context.id) }
    validate do |asset, errors, context:|
      errors.add(:owner_id, :not_permitted, message: "must belong to you") unless asset.owner_id == context.id
    end
  end
end
```

`with_options` shares `model`, `role`, `scopes`, and `conditions` within a block. `with_conditions` attaches requirements to permissions in its block. The adapter additionally supports inherited `requires_conditions`; see its README.

Hook signatures are checked at registration. Field resolvers accept `context:`, `action:`, `record:`, and `fields:`; create/update validators accept `context:` and `record:`, with explicit `errors:` selecting error-collection behavior. Optional keywords, keyword rest arguments, or one positional hash are supported. Invalid signatures raise `ArgumentError`.

## Dynamic field resolvers

Field declarations and enforcement are covered in the README. Use a resolver when the final field list needs extra application logic:

```ruby
Writ.configure do
  field_resolver model: Asset do |fields:, **|
    fields == :all ? :all : fields + ["display_name"]
  end
end
```

A resolver can return computed presentation keys; your serializer must implement them. Model-specific resolvers exclude global resolvers unless registered with `include_global: true`.

| Registration | Behavior |
|---|---|
| First resolver | Establishes the resolver for that model, or globally if no model is supplied. |
| Second resolver without options | Raises to prevent accidental override by load order. |
| `append: true` | Runs after existing resolvers, receiving their output. |
| `replace: true` | Replaces the existing chain. |

Resolver context is the same context used for authorization, including the selected tenant. Preserve `:all` unless deliberately replacing the complete field decision. Nested associations need separate authorization.

`declared_fields` unions declared action fields, returning `:all` if any action is unrestricted. Class arguments follow rule inheritance or an explicit model resolver; string arguments address stored model names directly. Existing stored arrays/nil retain their legacy all-action meaning and are preserved by generation.

## Rule inheritance and STI

The Pundit adapter registers rule inheritance when a model's policy inherits from its ancestor's policy. Core-only applications declare the same relationship directly:

```ruby
Writ.configure do
  inherit_rules model: Van, from: Vehicle
  inherit_rules model: Truck, from: Vehicle

  permission :read, model: Vehicle, role: :FleetManager
  permission :update, model: Vehicle, role: :FleetManager
  permission :delete, model: Truck, role: :FleetManager
end
```

Both models must belong to the same ActiveRecord STI hierarchy and use the same table. No inheritance is assumed from two unrelated policies sharing a utility superclass. Without a registered relationship or explicit resolver, rules use the exact model name.

| Rule | Inheritance behavior |
|---|---|
| Stored permissions | Ancestor grants apply to descendants. Child grants apply only to that child's subtree. |
| Named scopes | Children can reference ancestor definitions and their argument schemas. Stored attachments retain the defining scope's identity. |
| Default scopes | All ancestor boundaries and the child's boundary must pass. |
| Fields | For each role/action, the nearest explicit model entry wins; missing entries inherit before `field_default` applies. Fields from contributing roles then combine. |
| Field resolvers | Ancestor resolver chains run before child chains; the usual global inclusion settings still apply. |
| Lifecycle validators | Global and ancestor validators run before child validators, with each registration run once. |

These rules apply to both shared and tenant roles. A Vehicle default scope can enforce the tenant boundary for the entire hierarchy. Shared parent grants are stored once, so editing a Vehicle grant affects descendant access without synchronizing copies.

An explicit child field entry can be a list, `[]`, or `:all`. It replaces only that role's inherited entry for that action; it does not remove fields granted by another contributing role.

Named scopes resolve from the child toward its ancestors. Redefining an inherited name requires `replace: true`. That creates a child definition; it does not rewrite existing attachments to the parent's scope. The parent's original grants keep their original scope, while new child declarations resolve to the child definition. Scope arguments remain specific to each permission attachment.

Permissions remain additive. A scoped child update grant cannot narrow an inherited unrestricted update grant; put mandatory child restrictions in a child default scope.

### Collections

`filter(records: Truck)` preserves the Truck type constraint. `filter(records: Vehicle)` evaluates each subtype with its applicable grants and default boundaries. A general Vehicle grant cannot bypass a Truck default scope, and a Truck grant cannot expose Van rows. Relations stay lazy and preserve caller restrictions.

Individual-record checks, mixed STI arrays, batch field decisions, and collection filtering follow the same inherited rules. Ordinary model validations and callbacks are Rails behavior; they are not copied into Writ's registry.

### Explicit model resolution

An application can deliberately select one shared rule set instead of composing inherited rules:

```ruby
Writ.configure do |config|
  config.authorization_model_resolver = ->(model) { model.base_class }
end
```

The resolver must return the model or an ancestor in the same hierarchy/table. This explicit override keeps single-model behavior: grants are not merged across models, and subtype declarations do not add restrictions to the selected shared rule set. Filters retain the concrete subtype and caller restrictions.

Use policy inheritance or `inherit_rules` for ordinary shared parent rules with subtype additions. Reserve a resolver for applications deliberately choosing one authorization model for every operation.

## Reloading and standalone use

Rails loads `config/writ/**/*.rb` in sorted order inside a registry rebuild. The adapter then loads `app/policies`. Initializer `Writ.configure` blocks replay before these files. Keep model-dependent rules in definition files or adapter policies so reloadable models are available.

A failed rebuild preserves the previous published registry. Registries are process-local; database grant edits do not rebuild them. Manual rebuilding must run without in-flight authorization; concurrent registry replacement is unsupported. Use the Rails executor/reloader for background work.

For standalone ActiveRecord usage:

```ruby
require "rails_writ"
# Establish the ActiveRecord connection and load application/authorization models.
load "config/writ/permissions.rb"
```

Core model concerns are available without booting Rails. Configure custom authorization class names before including concerns. Standalone applications own definition loading and reloading. Railties remains an installation dependency, but Pundit does not.

## Tenant sources and compatibility settings

`scoping_model` accepts a model class or its constant name. Writ stores the name so Rails reloads resolve the current class. A configured model enables tenant mode. `tenant_source` receives the access-check context and must return a persisted instance of that model. Missing callbacks, nil tenants, wrong model types, and unsaved/destroyed tenants raise `Writ::ConfigurationError`.

The default role source intersects the actor's assigned roles with the tenant's roles. The default permission source uses that same tenant-filtered assignment set. This respects the generated associations' custom keys. Explicit `role_source` and `permission_source` callbacks override their respective lookups independently and are responsible for their own tenant restrictions.

The earlier `default_scoping_model` name remains an alias for `scoping_model`; `multi_tenant = true` also enables tenant mode. These settings are retained for custom integrations, but the generated setup uses `scoping_model` plus `tenant_source`. Setting `multi_tenant = false` does not disable a configured tenant model.

## Failure modes

All modes below default to `:raise`:

| Setting | Alternatives | Effect |
|---|---|---|
| `on_missing_condition` | `:deny` | Excludes a permission referring to an unknown condition. |
| `on_condition_error` | `:deny` | Excludes a permission whose condition raised. |
| `on_invalid_scope_arguments` | `:deny` | Excludes a grant with malformed stored scope arguments. |
| `on_invalid_condition_arguments` | `:deny` | Excludes a grant with malformed stored condition arguments. |
| `on_missing_default_scope` | `:warning`, `:skip` | Permits registration without the otherwise-required tenant boundary. |
| `on_missing_matcher` | `:warning`, `:skip` | Omits a proposed-state constraint that lacks a validator/matcher. |

`:deny` logs and excludes the affected grant; another valid grant can still authorize. `:warning` logs before omitting the missing constraint, while `:skip` omits it silently. Neither constructs a missing boundary or proposed validator. Scope query/validator exceptions propagate.

Invalid configuration is distinct from a valid proposal being denied. For example, a malformed stored scope argument is not a user field-validation error.
