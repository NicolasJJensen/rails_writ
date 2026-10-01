# Writ for Pundit

`rails_writ-pundit` connects Writ's stored roles and permissions to Pundit's policies, Strong Parameters, and controller helpers. It depends on `rails_writ` and `pundit`.

The [main README](https://github.com/NicolasJJensen/rails_writ#readme) covers basic setup, permissions, single-tenant and multi-tenant configuration, and complete create/update examples. This guide covers adapter customization.

## Contents

- [Installation](#installation)
- [Policies](#policies)
- [Controller helpers](#controller-helpers)
- [Nested parameters](#nested-parameters)
- [Custom actions](#custom-actions)
- [Shared conditions](#shared-conditions)
- [Loading and context](#loading-and-context)

## Installation

After the core setup:

```ruby
# Gemfile
gem "rails_writ-pundit"
```

```sh
bundle install
bin/rails generate writ:pundit:application_policy
```

For a fresh application, the combined installer creates the core setup and policy base:

```sh
bin/rails generate writ:pundit:install
bin/rails db:migrate
```

For organisation-owned roles:

```sh
bin/rails generate writ:pundit:install --multi-tenant --scoping-model=Organisation
bin/rails db:migrate
```

Both modes use:

```ruby
class ApplicationPolicy < Writ::Pundit::Policy
end
```

Review an existing customized policy base before replacing it. The adapter uses the core's schema and tenant configuration.

## Policies

When definitions live in `config/writ/*.rb`, an empty policy connects them to Pundit:

```ruby
class AssetPolicy < ApplicationPolicy
end
```

Alternatively, put definitions in policies. The policy infers its model:

```ruby
class AssetPolicy < ApplicationPolicy
  scope :owned do
    query { |context:| Asset.where(owner_id: context.id) }
    validate do |asset, errors, context:|
      errors.add(:owner_id, :not_permitted, message: "must belong to you") unless asset.owner_id == context.id
    end
  end

  role :Member do
    permission :read, scopes: [:owned]
    permission :create, scopes: [:owned]
    permission :update, scopes: [:owned]
    accessible_fields [:name, :description], action: :read
    accessible_fields [:name, :description], action: :create
    accessible_fields [:name], action: :update
  end
end
```

For tenant-owned records, also define the [default tenant scope](https://github.com/NicolasJJensen/rails_writ#default-scopes-and-tenants), omitting `model:` inside the policy. Put each declaration in one place.

## Controller helpers

Include the usual Pundit module:

```ruby
class ApplicationController < ActionController::Base
  include Pundit::Authorization
end
```

| Helper | Behavior |
|---|---|
| `policy_scope(Asset)` | Filters the saved relation using `:read`. |
| `authorize @asset, :update?` | Checks saved access; create checks grant availability. |
| `permitted_attributes(@asset)` | Reads Pundit's parameter root and permits the policy's field list. |
| `authorize_proposed!(@asset)` | Checks dirty fields and proposed scope/lifecycle rules. |
| `authorize_proposed!(@asset, attributes: input)` | Assigns input, then checks all supplied keys and proposed rules. |

The proposed helper is available automatically, including when Pundit was already included before the adapter loaded. It does not save or replace ordinary `authorize`. It infers `:create`/`:update` from the record; `action:` overrides that inference.

Omitted `attributes:` uses `changed_attribute_names_to_save`. Explicit `{}` means no submitted fields. Unpermitted `ActionController::Parameters` are rejected by Rails assignment. The policy hooks `permitted_attributes_for_create` and `permitted_attributes_for_update` use Writ's candidate fields; `:all` expands to model attribute names, not `permit!`.

A proposed failure raises `Writ::Pundit::ProposedAuthorizationError` with `record` and `result`, and attaches final errors to the record. Missing authority raises ordinary `Pundit::NotAuthorizedError`. See the main README for [HTML, Turbo, and JSON error handling](https://github.com/NicolasJJensen/rails_writ#rendering-errors).

## Nested parameters

Pundit normally reads `params.require(:asset)` for an Asset. To change the request envelope, override its hook in your controller:

```ruby
def pundit_params_for(record)
  params.require(:data).require(Pundit::PolicyFinder.new(record).param_key)
end
```

Stored field names do not describe nested Strong Parameters structures. If an allowed field needs a schema, replace that entry in the policy's result:

```ruby
# Inside AssetPolicy; the role's create fields must include :tags.
def permitted_attributes_for_create
  super.map { |field| field == :tags ? { tags: [] } : field }
end
```

For nested attributes, supply an explicit allowlist such as `{ attachments_attributes: [:id, :caption] }` only when that field is allowed. Authorize associated records separately; permitting a nested shape does not authorize its records or make pending association changes supported by proposed validation.

## Custom actions

Built-in predicates map as follows:

| Predicates | Action |
|---|---|
| `index?`, `show?`, `read?` | `:read` |
| `new?`, `create?` | `:create` |
| `edit?`, `update?` | `:update` |
| `destroy?`, `delete?` | `:delete` |

Add explicit methods for other actions:

```ruby
# Inside AssetPolicy
role :Member do
  permission :publish, scopes: [:owned]
end

def publish?
  permitted?(:publish)
end
```

The generator can emit these predicates:

```sh
bin/rails generate writ:pundit:policy Asset --roles Member --actions read publish
```

Unknown predicates raise `NoMethodError`. The policy generator rejects action names that collide with CRUD aliases, `permitted`, or inherited Ruby predicates. Apply new defaults to existing stored roles before using them.

## Shared conditions

Define shared conditions before requiring them on descendant permissions:

```ruby
class ApplicationPolicy < Writ::Pundit::Policy
  condition :business_hours do |_context|
    (9...17).cover?(Time.current.hour)
  end
  requires_conditions :business_hours
end
```

`requires_conditions` must precede local permission declarations. `with_conditions :business_hours do ... end` limits the requirement to its block. Requirements combine and deduplicate; conflicting arguments raise.

## Loading and context

The adapter loads `app/policies` during Writ registry rebuilds, after `config/writ/*.rb`. Reloads rebuild both against current model classes.

Pundit uses `current_user` by default. Override `pundit_user` for an application-specific context and configure Writ's sources accordingly. Tenant applications normally only need `scoping_model`, `tenant_source`, and default scopes. If the user or tenant changes within a controller instance, call `pundit_reset!` before reusing cached Pundit objects.

Use `Writ::Pundit::PolicyHelpers` directly only when implementing a custom policy base; the ready-made `Policy` supplies predicates and `Scope#resolve`.

Both packages are tested from the repository root. The adapter uses the [MIT License](LICENSE.txt).
