# Writ

A Rails/ActiveRecord authorization gem with database-backed roles and grants, composable record scopes, and contextual conditions. The bundled migrations use PostgreSQL JSONB. A single-column primary key is required (including UUID and custom column names); composite keys are rejected explicitly.

The gem does not depend on a serializer, controller framework, GraphQL library, or transport. The host enforces decisions at its boundaries. It does not support arbitrary ORMs or plain Ruby resource records through the SQL filtering API.

## Installation and host boundaries

Add the gem to your Gemfile:

```ruby
gem "rails_writ"
```

Then run `bundle install`.

Create the host model that will receive roles before running the installer. By
default this is `User`; use `--roleable-model` when the actor model has another
name. In multi-tenant mode, also create the scoping model (by default
`Organisation`) before running the installer. The generator adds the
`Writ::Roleable` integration to these existing application
models; it does not create them.

Generate a conventional setup with `rails generate writ:install`.
For tenant-owned roles, pass `--multi-tenant --scoping-model=Organisation`.
Use `--roleable-model=Account` for a different actor model and
`--model-namespace=Authorization` to generate `Authorization::Role`,
`Authorization::Permission`, and the related models in prefixed tables.
The generated initializer configures these class names before the models load.
Namespaced host models are accepted; loaded model table names are respected.
For an unloaded host model, the fallback is its demodulized conventional table name.
Generators infer host primary-key names and types from existing tables, including UUID,
string keys, and 64-bit integer IDs. For models/tables that are not available yet, use
explicit options (the conventional fallback is an `id` bigint):

```sh
rails generate writ:install --multi-tenant --roleable-model=Account \
  --roleable-primary-key=account_uuid --roleable-primary-key-type=uuid \
  --scoping-primary-key=organisation_uuid --scoping-primary-key-type=uuid
```

Supported explicit key types are `bigint`, `integer`, `uuid`, and `string`.
The host models must declare their actual `self.primary_key` when it is not `id`.
Composite keys are rejected before generation. Review migrations against the host schema;
these options generate references and do not change the host's own primary keys.
Custom authorization models must share a database connection for atomic generation/cleanup.

In multi-tenant mode, the scoping model owns roles and is the tenant passed to
`rake writ:generate`. The roleable model is the actor that receives those
roles; it is not a valid `MODEL` for that rake task. For example, with
`config.default_scoping_model = 'Organisation'`, use
`ID=42 MODEL=Organisation rake writ:generate`. The task validates this
model before looking up the record or generating any roles. A custom configured scoping
class is supported when `default_scoping_model` names that class.

Membership tables follow Rails' HABTM naming convention, including shared-prefix removal.
Both generated Role associations and `as_roleable` use Rails inference. For example,
`review_auth_accounts` and `review_auth_roles` use `review_auth_accounts_roles`.
Existing installations generated with the older concatenated name need a host migration
to rename that table (for example, from `review_auth_accounts_review_auth_roles`) and removal
of the old generated `join_table:` override. The gem does not rename existing tables.
Generated models inherit the conventional `ApplicationRecord`; customize them in the host
when using another abstract base class or intentionally custom associations.

`require 'rails_writ'` loads the reusable model and policy concerns in
standalone ActiveRecord hosts too. Rails additionally supplies policy autoloading,
generators, and rake integration. The authorization model associations must be configured
before including the model concerns.

The generated initializer is a starting point and does not list every available
operational setting. The following settings can be added to its `configure` block when
the host needs a different policy for invalid or incomplete authorization data:

* `on_missing_default_scope` accepts `:raise`, `:warning`, or `:skip` and defaults to
  `:raise`. It controls what happens when a scoped model has no tenant default scope.
* `on_invalid_scope_arguments` accepts `:raise` or `:deny` and defaults to `:raise`. It
  controls what happens when stored scope arguments fail their registered schema.
* `on_invalid_condition_arguments` accepts `:raise` or `:deny` and defaults to `:raise`.
  It controls what happens when stored condition arguments fail their registered schema.

The `:raise` modes surface invalid configuration or data by raising an error. The `:warning`
and `:skip` modes for missing default scopes allow evaluation to continue, while `:deny`
excludes the affected permission when its stored scope or condition arguments are invalid.

The generated `ApplicationPolicy` defines explicit `index?`, `show?`, `read?`, `new?`,
`create?`, `edit?`, `update?`, `destroy?`, and `delete?` predicates. A model policy generated
with `--actions approve` adds an explicit `approve?` predicate. Unknown predicate names raise
`NoMethodError`; they are not converted into permission actions implicitly. The generator
reserves `index`, `show`, `new`, `edit`, `destroy`, `permitted`, and inherited Ruby predicate names
such as `respond_to` and `is_a`; these names would override policy or object introspection methods.
Use `read`, `create`, `update`, `delete`, or another custom action.

Custom actions use the same explicit contract in hand-written policies:

```ruby
class AssetPolicy < ApplicationPolicy
  def publish?
    permitted?(:publish)
  end
end

Pundit.authorize(current_user, asset, :publish?)
```

Register the matching `:publish` permission in the policy definition. Pundit checks for
misspelled or unimplemented predicates fail with `NoMethodError` instead of being treated as
permission actions.

## Public contracts

```ruby
Access = Writ::Access
Access.grant_available?(context: actor, action: :read, model: Asset)
Access.filter(context: actor, action: :read, records: Asset.all).order(:name).limit(20)
```

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

Other denial reasons include `:no_permission_source`, `:condition_error`, `:missing_condition`,
`:condition_arguments_invalid`, and `:scope_arguments_invalid`. A successful result has an empty
`denied_grants` array. The gem returns decision data; host applications own messages, translations,
and response formatting.

* `grant_available?` checks grant conditions but intentionally ignores record scopes. Use for potential navigation/action availability, never to authorize a particular record.
* `filter` returns a lazy ActiveRecord relation. Scopes within a grant intersect; grants across roles form a union. Default policy scopes constrain every grant. No explicit deny overrides a separate valid grant.
* An authorization result for a collection requires **all records before pagination** to be permitted. An empty collection passes. ORDER, LIMIT, and OFFSET are stripped. Filter first, then paginate.
* Query projections and caller restrictions survive filtering and permission annotations. Scope projections are ignored when computing membership. Grouped relations are rejected.
* SQL filtering expects the model's normal table qualifier. For derived queries, use `Asset.from(inner_relation, :assets)` (substitute the real model table name). Arbitrary `FROM` aliases such as `assets AS other_assets` are not supported; adapt the query in the host before filtering.
* `potential_permissions` is potential grant metadata; it does not evaluate scopes or conditions.

## Context and configuration

The default context protocol is `permissions`, returning an ActiveRecord Permission relation. Model-wide field metadata also uses `roles`, returning a Role relation. The context need not itself be an ActiveRecord object, and may carry tenant, device, or request state. The caller must supply a permission relation appropriate for the actor and tenant.

```ruby
Writ.configure do |config|
  config.permission_class = 'Authorization::Permission'
  config.role_class = 'Authorization::Role'
  config.permission_source = ->(context) { context.permissions_for_current_tenant }
  config.role_source = ->(context) { context.roles_for_current_tenant }
  config.on_missing_condition = :deny
  config.on_condition_error = :raise
  config.on_missing_default_scope = :warning
  config.on_missing_matcher = :raise
  config.on_invalid_scope_arguments = :deny
  config.on_invalid_condition_arguments = :deny
  config.field_default = []
end
```

When `multi_tenant` is enabled or unset, a model with record scopes should declare a default
scope that applies the tenant boundary. `on_missing_default_scope` accepts `:raise`, `:warning`,
or `:skip`; its default is `:raise`. Use `:warning` or `:skip` only when the host accepts a
missing default scope for the configured model.
`on_missing_matcher` accepts `:raise`, `:warning`, or `:skip` for proposed-state validation.
`:raise` protects development and test environments. `:warning` logs and skips the missing
matcher. `:skip` evaluates the other matchers and does not require the missing matcher.

Register scopes, conditions, field resolvers, and validators with blocks in this DSL.
Model-specific field resolvers and creation/update validators have no setter-style APIs.
`field_default` remains a direct configuration setting and accepts `:all` or an array of
field names.

Rule implementations are registered with blocks only. Scope and condition blocks receive no
arguments, the context as one positional argument, or `(context, arguments)` for a parameterized
rule. Field resolvers and lifecycle validators use their documented keyword arguments. The
registration API does not accept Proc, Method, or Symbol values through a `callable:` option;
the registry stores the supplied blocks internally after registration.

The registry stores rule definitions and their metadata. Use it for generation, diagnostics, and
field declarations. It does not grant access. `Access.authorization`, `Access.validation`, and
`Access.filter` evaluate rules against a supplied context and subject.

Set `on_missing_default_scope = :raise` when every configured model must declare a default
scope. Exempt a deliberately global model in the same configuration block:

```ruby
Writ.configure do
  self.on_missing_default_scope = :raise
  allow_missing_default_scope model: Country
  scope :published, model: Article do |_context|
    Article.where(published: true)
  end
end
```

An exemption applies only to its model. It does not add a scope or permit a record.

Rule names identify one definition. A duplicate scope, default scope, or condition declaration
raises with both declaration locations. Use `replace: true` only when the later declaration must
replace the earlier definition:

```ruby
Writ.configure do
  scope :published, model: Article, replace: true do |_context|
    Article.where(published: true)
  end
end
```

Hook signatures are checked when the registry is built. Field resolvers must accept
`context:`, `action:`, `record:`, and `fields:`; creation and update validators must accept
`context:` and `record:`. Registration blocks can accept optional keywords, `**kwargs`, or one
positional hash. Invalid signatures raise `ArgumentError` during registration,
before the hook is persisted.

### STI policy resolution

Authorization uses exact model names by default. To share a policy across an STI hierarchy,
opt in explicitly:

```ruby
Writ.configure do |config|
  config.authorization_model_resolver = ->(model) { model.base_class }
end
```

The resolver selects the model whose grants, scopes, matchers, and fields are used. It must
return the input model or an ancestor in the same STI hierarchy and table. It does not merge
base and subclass grants. Record filters retain the concrete subtype and caller restrictions.
A base-model list intentionally uses the base policy for every row; the default exact-model
mode does not automatically apply subclass policies to those rows. Choose a consistent
resolution strategy for lists and individual records in an STI integration.

Custom model constant names and logger settings survive reload. Custom models must provide the same associations and storage contract as the generated models; configuring class names does not rewrite consumer associations.

Register definitions outside `app/policies` in an initializer `configure` block:

```ruby
Writ.configure do
  condition(:signed_in) { |context| context.user.present? }
  scope(:own, model: Asset) { |context| Asset.where(owner_id: context.user.id) }
end
```

Conditions can be required across a policy hierarchy or added lexically to a group of permissions.
Requirements are additive and deduplicated; a conflicting argument declaration raises during policy
loading. An abstract base policy does not need a model:

```ruby
class MfaRequiredPolicy
  include Writ::PolicyHelpers
  requires_conditions :mfa_enabled
end

class AssetPolicy < MfaRequiredPolicy
  with_conditions :during_business_hours do
    role :Operator do
      permission :read
    end
  end
end
```

`with_conditions` is scoped to its block. `requires_conditions` must be declared before local
permissions. A bare parameterized condition may remain a template during boot; supply tenant values
when generating defaults with `condition_arguments:` as shown below. No condition becomes a universal
guard unless it is attached through one of these declarations.

Each `configure` block is replayed before policies during registry rebuilding. Resolve reloadable constants inside the block. Static settings in a block are also replayed. A failed rebuild leaves the previous registry published. Consumer-managed loading can call `Configuration.rebuild! { ... }` to build and validate a replacement.
Registry definitions are process-local: boot and Rails-managed class reloads rebuild them.
Changing stored roles or grants does not rebuild the registry. Rolling deployments that replace
instances start independent registries and need no cross-instance snapshot mechanism.
Manual rebuilding must run without in-flight authorization; concurrent hot-swapping is not
supported. Use the Rails executor/reloader for host-managed background execution.

## Serializer-independent fields

```ruby
role :Technician do
  permission :read
  permission :update, scopes: [:own]
  accessible_fields [:name, :description], action: :read
  accessible_fields [:name], action: :update
end

Access.readable_fields(context: actor, record: asset)
Access.writable_fields(context: actor, record: asset, action: :update)
```

The result is `:all` or an array of string field names. No effective grant means `[]`. Only roles with matching grants contribute. For a persisted record, conditions and record scopes are evaluated before fields are combined. Passing a model class checks grant availability only. Field names may represent computed presentation keys; the gem does not introspect a serializer.

`accessible_fields [...]` with an omitted or `nil` action is shorthand for four declarations:
`:create`, `:read`, `:update`, and `:delete`. Pass an explicit action as a String or Symbol, such
as `action: :read` or `action: "publish"`, to configure one action. Each action has an independent field list. A later declaration
**replaces** that action's list; it does not union it with the earlier list:

```ruby
accessible_fields [:name]
accessible_fields [:name, :description], action: :read
# create: ["name"], read: ["name", "description"], update: ["name"], delete: ["name"]
```

A later shorthand replaces all four CRUD lists but leaves explicitly configured custom
actions unchanged. The shorthand does not configure custom actions such as `:approve`.
The default is `:all`; configure `field_default = []` for explicit opt-in fields.
Explicit `:all`/stored `nil` is unrestricted, and `[]` means no fields. Missing action
entries use the configured default. Different effective roles still combine their grants
and fields by union. If any effective grant contributes `:all`, the combined value passed to
field resolvers is `:all`; under this union semantics, a `:all` field grant cannot be narrowed
by another grant. Resolvers should preserve `:all` unless the application deliberately owns a
replacement policy for the complete result.

`declared_fields` remains metadata only and does not authorize a record. It returns
the union of declared action fields, or `:all` if any declared action is unrestricted.
Class arguments follow the configured STI resolver; string arguments address stored model
names directly. Existing database arrays/nil retain their legacy all-action meaning.
Generation preserves those existing host-owned values; the new shorthand applies to new
definitions and does not rewrite existing roles.

For dynamic or nested presentation conventions, register a global field resolver in the configuration DSL, or register a model resolver in a policy. A model resolver includes the global resolver only when `include_global: true`:

```ruby
Writ.configure do |config|
  config.field_resolver do |context:, action:, record:, fields:|
    # Return :all or a list of names understood by your serializer/form.
    fields
  end
end
```

Each model, including the global resolver, starts with one resolver. Registering a second
resolver for the same model raises so that configuration load order cannot silently change
field access. Use `append: true` when independent rules should both apply; they run in
declaration order and each receives the fields returned by the prior resolver. Use
`replace: true` when the later declaration intentionally discards the existing resolver
chain.

```ruby
class AssetPolicy < ApplicationPolicy
  field_resolver do |fields:, **|
    fields == :all ? :all : fields + ["display_name"]
  end
end

Writ.configure do |config|
  config.field_resolver(model: Asset, append: true) do |context:, fields:, **|
    if fields == :all
      :all
    elsif context.external_user?
      fields - ["internal_cost"]
    else
      fields
    end
  end
end
```

Use composition when each resolver expresses a separate rule. A replacement is appropriate
when an application deliberately takes ownership of the complete result:

```ruby
Writ.configure do |config|
  config.field_resolver(model: Asset, replace: true) do |context:, **|
    context.admin? ? :all : []
  end
end
```

A serializer should intersect its own field selection with readable fields. A command/form should reject or filter input keys against writable fields and separately authorize the action. Nested associations must be authorized independently. Neither field query mutates a record, serializes data, or permits parameters. Hoist model-wide decisions outside per-record loops where appropriate; record-aware fields can require membership queries per grant. No global permission-result cache is used.

## Batch fields

```ruby
records = Access.filter(context: actor, action: :read, records: Asset).limit(50).to_a
fields_by_record = Access.fields_for_many(context: actor, action: :read, records: records)
# { asset => ["name", ...] } -- or :all
```

The input must contain persisted records resolving to one authorization model, with a loaded
single-column primary key. Composite primary-key models are not supported by batch field
decisions.
The result maps each record to its effective fields; denied records receive `[]`.
An empty batch returns `{}`.

For each call, the gem loads permission metadata once, then runs one membership query for
each contributing role and concrete record-class group. A page of 50 `Asset` records with
three grants on one role therefore uses one membership query, not 50. A heterogeneous STI
batch with `StiTruck` and `StiVan` records that both resolve to `StiAsset`, and three
contributing roles, uses six membership queries: two concrete subtype groups times three
roles. Resolvers still run once per authorized record.

Keep batches bounded and group heterogeneous data when that query shape matters. Keep
context stable during a batch; there is no result cache across calls. Field queries do not
themselves serialize or permit input parameters.

## Creation

A proposed record cannot use saved SQL membership. `validation` checks create-grant conditions,
declared default/scope `matches:` predicates, and optional creation validators:

```ruby
Writ.configure do |config|
  config.creation_validator do |context:, record:|
    record.organisation_id == context.organisation.id &&
      context.allowed_location_ids.include?(record.location_id)
  end
end
```

Without a validator, an unscoped create grant can authorize when its conditions pass. A validator is responsible for proposed attributes and host constraints. Persisted SQL scopes are not translated into predicates for unsaved objects. Model-specific `creation_validator` declarations run after global declarations and all must pass. A class-level grant check does not validate proposed state.

Default-role assignment is a host decision. `as_roleable(scoping_model: true)` generates defaults for the tenant; it does not automatically attach the default role to new users. Add that callback/service explicitly if wanted. Repeating identical `as_roleable` setup is
a no-op, including on subclasses that inherit it. Conflicting setup raises an error.

## Updates with pending attributes

Authorize the saved record before assignment. Validate the proposed record after assignment.
Neither operation saves, reloads, or clears the caller's changes.

Scopes can use `matches:` alongside their SQL implementation:

```ruby
class AssetPolicy < ApplicationPolicy
  default_scope matches: ->(context, record) {
    record.organisation_id == context.organisation_id
  } do |context|
    Asset.where(organisation_id: context.organisation_id)
  end

  scope :assigned_locations,
        matches: ->(context, record) { context.location_ids.include?(record.location_id) } do |context|
    Asset.where(location_id: context.location_ids)
  end

  role :Technician do
    permission :update, scopes: [:assigned_locations]
  end
end

```

The SQL scope authorizes the saved state. Its matcher validates the supplied proposed record.
The gem does not copy the record, rerun attribute setters, or reconcile stale attributes with the database.
Record freshness and concurrency are host responsibilities.
A parameterized scope uses `matches: ->(context, record, args) { ... }` and receives its validated stored arguments.
PolicyHelpers and `Writ.configure` both accept matchers.

Scopes within each grant intersect. Separate grants form a union, so different grants can authorize the two states.
Conditions run once per grant. The default matcher constrains every proposed grant.
For saved SQL authorization, the registered default scope is applied once per evaluation and
constrains the union of valid grants. Each grant's own scopes still intersect within that grant.
Missing matchers raise `ConfigurationError` by default. Set `config.on_missing_matcher = :warning` to log and skip only the missing proposed-state matcher, or use `:skip` without the warning. Existing matchers still run, false results still deny, and matcher errors still propagate. Neither mode makes an otherwise unconstrained grant validate proposed attributes.
A model with ActiveRecord default scopes also requires a default matcher that represents its applicable constraints.
Keep SQL scopes and matchers equivalent. Test both with representative permitted and denied values.

Validation requires a persisted record with its unchanged primary key. It rejects pending changes to loaded associated records.
It supports direct attributes, including foreign keys. Authorize association and nested-record operations separately.
Some association setters write immediately. Do not use those setters to construct a proposed record.

Permission scope and condition attachments support nested attributes, including
`_destroy: true` for removing an existing attachment. The host must authorize changes to these
attachments as permission configuration changes. The association writes remain part of the
permission save transaction.
Matcher exceptions propagate. Matchers must treat the record and context as read-only.

`update_validator` declarations apply only to `Access.validation(subject: record, action: :update, context:)`.
They run after proposed scope matchers. They do not change saved authorization or the generated
`update?` policy method. Global and model-specific update validators run in declaration order.
Every validator must pass. Creation validators use the same global-then-model ordering.

The canonical update flow separates saved authorization from proposed validation. Check the saved
record before assignment, assign the attributes, then validate the changed record before saving:

```ruby
saved = Access.authorization(subject: asset, action: :update, context: user)
raise Pundit::NotAuthorizedError unless saved.allowed?

asset.assign_attributes(attributes)
proposed = Access.validation(subject: asset, action: :update, context: user)
raise Pundit::NotAuthorizedError unless proposed.allowed?
asset.save!
```

Generated Pundit `new?` and `create?` methods use `authorization` for a new record. They check
the create-class grant and its conditions. They do not run matchers or validators. Use
`validation` for a new record with `action: :create` before saving it. A model-class
authorization result also shows grant availability and does not validate proposed attributes.

Field authorization remains separate. Check writable fields against the saved state before assigning request attributes.
When concurrency protection is needed, perform the check and save inside the same transaction
while holding a lock on the record. Acquire the lock before assigning changes; `with_lock`
reloads the saved record before entering the block:

```ruby
asset.with_lock do
  saved = Access.authorization(subject: asset, action: :update, context: user)
  raise Pundit::NotAuthorizedError unless saved.allowed?

  permitted_fields = Access.writable_fields(context: user, record: asset, action: :update)
  submitted_fields = attributes.keys.map(&:to_s)
  raise Pundit::NotAuthorizedError unless permitted_fields == :all || submitted_fields.all? { |field| permitted_fields.include?(field) }

  asset.assign_attributes(attributes)
  proposed = Access.validation(subject: asset, action: :update, context: user)
  raise Pundit::NotAuthorizedError unless proposed.allowed?
  asset.save!
end
```

Lock relevant related records too when their concurrent changes could invalidate the decision.
Callbacks that change authorization-sensitive attributes must run before this check or enforce equivalent constraints themselves.
Both states being permitted does not authorize every business transition between them. Use distinct actions for operations such as approval.

## Organisation setup and permission migrations

New organisations receive their configured defaults through `as_roleable(scoping_model: true)`.
`Generator.generate_default_permissions(organisation)` initializes an organisation with no roles.
It rejects organisations that already have roles. Global initialization requires `multi_tenant = false` and an empty role table.

For required, tenant-specific condition arguments, keep the policy registration as a bare or partial
template and provide values when generating each tenant's defaults. Supplied values with the wrong
type or unknown keys fail during configuration loading; missing required values fail when a concrete
permission is saved. This does not mutate the process-wide registry:

```ruby
Writ::Generator.generate_default_permissions(
  organisation,
  condition_arguments: { tenant_ids: { ids: [organisation.id] } }
)
```

The host can disable automatic default generation and call this method from its tenant setup service when
it needs to derive these arguments from tenant state. Missing required values fail the generation transaction.

Existing organisations own their grants and fields. Changes to code defaults do not update their configuration.
When a new model or action enters the application, use an explicit data migration:

```ruby
Organisation.find_each do |organisation|
  Writ::Generator.add_permissions(
    organisation,
    permissions: [
      { model: Asset, action: :approve },
      { model: Inspection, action: :read },
      { model: Inspection, action: :create }
    ],
    condition_arguments: { tenant_ids: { ids: [organisation.id] } }
  )
end
```

The selection identifies model/action pairs in the current policy definitions. Unknown or empty selections raise before writes.
For each configured role, the migration adds the selected action only when that role has no grant for that model/action.
All alternative grants for a missing action are created together. Existing scoped or customized grants count as existing permissions.
Repeated migration calls do not add duplicates. The migration preserves other actions, role descriptions, and the organisation's default role.
It creates a configured role when that role is missing. Renamed roles remain unchanged.

New actions can receive missing action-specific field entries. Existing model-wide and action-specific field values remain unchanged.
An explicit model-wide restriction therefore continues to apply to new actions.
Each organisation runs in a transaction. Role locks serialize changes within an existing role.
Migrations use the definitions loaded by the application. Keep those definitions stable while the migration runs.
A newly introduced alternative scope for an existing action needs an explicit host migration because this API preserves existing actions.

`Generator.generate_permissions` remains available for migrations that supply complete grant definitions directly.
It also preserves existing model/action grants and field values. It does not synchronize an organisation with all current defaults.
Use `add_permissions` for migrations that select definitions from policies.

The schema includes `permissions.generated_signature` and `roles.generated_fields` for provenance.
Cleanup is a separate, explicit retirement operation. Preview it with `DRY_RUN=1` before using `CONFIRM=1`.
Hosts can call the cleanup service programmatically with a registry and stale-item set when a
deployment task needs its own transaction or reporting. The rake task is a host-facing wrapper
around the same operation.
Cleanup removes unchanged, tracked obsolete defaults for roles still recognized by name in
the registry. A role with an unrecognized name may have been renamed by its tenant; cleanup
preserves it. Retire renamed roles or wholly removed role definitions through an explicit
host migration. Cleanup also preserves custom grants, referenced scope/condition catalog
rows, and field restrictions used by any surviving grant (including unchanged configured
grants). It rechecks role names and field dependencies under locks before deletion.
If a role is renamed after the cleanup scan, its scanned grants and fields are skipped,
including when the new name is another configured role.
It does not regenerate or reset permissions.

Changing or removing a rule schema requires a host data migration for affected grants.
Runtime checks reject nonempty stored arguments when the rule no longer accepts arguments.
The configured invalid-argument mode determines whether the check raises or excludes that grant.
Callbacks should treat their inputs as read-only. Normalized argument values are copied between evaluations.

Existing installations that predate provenance tracking need an additive host migration:

```ruby
add_column :permissions, :generated_signature, :string
add_column :roles, :generated_fields, :jsonb, default: {}, null: false
```

Use your authorization table names. Leave existing provenance unset.
Do not mark custom grants as generated through an indiscriminate backfill.
Existing Role models also need the inverse actor membership association, such as `has_and_belongs_to_many :users`.
Review generated model templates before applying them to customized models.

## Observability

Subscribe to `permission.check.writ` and `permission.filter.writ` using ActiveSupport::Notifications. Filter events include grant counts and a reason (`no_permission_source`, `no_grants`, `no_valid_grants`, `filtered`, or `error`). Error events contain the exception class, not its potentially sensitive message.

Filter `duration_ms` uses a monotonic clock and measures **query construction**, including loading grant metadata and executing Ruby conditions, not eventual record-query execution. `timing: 'query_construction'` makes that distinction explicit. Use ActiveRecord SQL notifications for database execution timing. Event delivery does not load the returned relation or count matching records. Scope/condition argument metadata is assembled only with a subscriber and contains stored arguments; treat it as potentially sensitive in your logger.

## Validation

```sh
bundle exec rspec
```

The test app uses `writ_test` in local PostgreSQL. Contract specs cover query composition, projections, custom keys/contexts, callback retries, registry rebuilding, generators, field decisions, and cleanup provenance. Host integrations should also test their own serializers, validators, and permission-source tenant isolation. Validate supported Ruby/Rails combinations before broadening version claims.

## Compatibility checks

The CI workflow has frozen baselines for the committed root and Rails 8.1 lockfiles,
using Ruby 3.3 and 3.4 respectively. These lockfiles include Linux platforms for CI.
A separate fresh-resolution matrix updates dependencies for Rails 7.0/7.1/7.2/8.0/8.1
on Ruby 3.1/3.2/3.3/3.3/3.4 respectively, with PostgreSQL. It intentionally updates even
the Rails 8.1 lockfile within that job, without changing the committed baseline.
These are test targets; a configured matrix is not evidence that every job has passed.
Each job runs the full suite, including generated-host lifecycle,
real class unloading/eager loading, and optional Pundit integration. Pundit is only a
development dependency. Rails/Ruby minimums follow the [Rails upgrade guide](https://guides.rubyonrails.org/upgrading_ruby_on_rails.html);
test framework versions follow [RSpec Rails compatibility guidance](https://github.com/rspec/rspec-rails).

Run an alternate bundle locally, for example:

```sh
BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle exec rspec
```

## Performance profiling

From the source checkout, run `bundle exec ruby benchmarks/permission_queries.rb` against the local test database.
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

## Release boundary

Runtime dependencies accept Rails components from 7.0 through 8.x (`< 9.0`). Future major
versions require a compatibility review before widening that range. Railties remains an
installation dependency; standalone ActiveRecord hosts can load the core without booting
Rails. The package includes the MIT license.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/NicolasJJensen/rails_writ.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
