# Configuration

[Back to README](../README.md) · [Documentation index](README.md)

Configure context sources, rule definitions, and reload behavior here. Field resolvers are covered in [Field permissions](fields.md).

## Context sources

The default context protocol is `permissions`, returning an ActiveRecord Permission relation. Model-wide field metadata also uses `roles`, returning a Role relation. The context need not itself be an ActiveRecord object, and may carry tenant, device, or request state. The caller must supply a permission relation appropriate for the actor and tenant.

```ruby
Writ.configure do |config|
  config.permission_class = 'Authorization::Permission'
  config.role_class = 'Authorization::Role'
  config.permission_source = ->(context) { context.permissions_for_current_tenant }
  config.role_source = ->(context) { context.roles_for_current_tenant }
  config.on_missing_condition = :deny
  config.on_condition_error = :raise
  config.on_missing_default_scope = :raise
  config.on_missing_matcher = :raise
  config.on_invalid_scope_arguments = :deny
  config.on_invalid_condition_arguments = :deny
  config.field_default = []
end
```

## Failure modes

The generated initializer lists common settings. All settings below default to `:raise`.

| Setting | Accepted values | Applies when |
|---|---|---|
| `on_missing_condition` | `:raise`, `:deny` | A grant references an unregistered condition. |
| `on_condition_error` | `:raise`, `:deny` | A condition raises during evaluation. |
| `on_invalid_scope_arguments` | `:raise`, `:deny` | Stored scope arguments fail their schema. |
| `on_invalid_condition_arguments` | `:raise`, `:deny` | Stored condition arguments fail their schema. |
| `on_missing_default_scope` | `:raise`, `:warning`, `:skip` | A scoped model requires a default scope but has none. |
| `on_missing_matcher` | `:raise`, `:warning`, `:skip` | Proposed-state validation needs a missing matcher. |

`:raise` surfaces the error; `:deny` excludes the affected grant. Other valid grants can still allow access.
For missing default scopes or matchers, `:warning` logs and continues without the missing constraint;
`:skip` does so without the warning. Choose these modes only when the application accepts that missing constraint.

When `multi_tenant` is enabled or unset, a model with record scopes should declare a default
scope for its tenant boundary. Keep SQL scopes and proposed-state matchers equivalent; see
[Creating and updating records](record-changes.md).

## Registering rules

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

## STI policy resolution

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

## Conditions and policy inheritance

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
when generating defaults with `condition_arguments:` as shown in the [permission lifecycle guide](permission-lifecycle.md). No condition becomes a universal
guard unless it is attached through one of these declarations.

## Reloading

Each `configure` block is replayed before policies during registry rebuilding. Resolve reloadable constants inside the block. Static settings in a block are also replayed. A failed rebuild leaves the previous registry published. Consumer-managed loading can call `Configuration.rebuild! { ... }` to build and validate a replacement.
Registry definitions are process-local: boot and Rails-managed class reloads rebuild them.
Changing stored roles or grants does not rebuild the registry. Rolling deployments that replace
instances start independent registries and need no cross-instance snapshot mechanism.
Manual rebuilding must run without in-flight authorization; concurrent hot-swapping is not
supported. Use the Rails executor/reloader for host-managed background execution.
