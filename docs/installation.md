# Installation and integration

[Back to README](../README.md) · [Documentation index](README.md)

Start with the [quick start](../README.md#quick-start). This guide covers custom models, tenant setup, and policy integration.

## Models and generators

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

Generated models inherit the conventional `ApplicationRecord`; customize them in the host
when using another abstract base class or intentionally custom associations.

`require 'rails_writ'` loads the reusable model and policy concerns in
standalone ActiveRecord hosts too. Rails additionally supplies policy autoloading,
generators, and rake integration. The authorization model associations must be configured
before including the model concerns.

## Policy integration

Pundit is optional and must be installed separately if you use its helpers or exceptions.

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

See the [upgrade guide](upgrading.md) for existing installations.
