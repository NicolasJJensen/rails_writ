# Writ for Pundit

`rails_writ-pundit` connects Writ's stored roles and permissions to Pundit's policies, Strong Parameters, and controller helpers. It depends on `rails_writ` and `pundit`.

The [main README](https://github.com/NicolasJJensen/rails_writ#readme) covers basic setup, permissions, single-tenant and multi-tenant configuration, and complete create/update examples. This guide covers adapter customization.

## Contents

- [Installation](#installation)
- [Policies](#policies)
- [Policy inheritance](#policy-inheritance)
- [Controller helpers](#controller-helpers)
- [Permitted attributes](#permitted-attributes)
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

## Policy inheritance

For models sharing a Rails STI hierarchy, inherit their policies too:

```ruby
class VehiclePolicy < ApplicationPolicy
  scope :owned do
    query { |context:| Vehicle.where(owner_id: context.id) }
    validate do |vehicle, errors, context:|
      errors.add(:owner_id, :not_permitted) unless vehicle.owner_id == context.id
    end
  end

  role :FleetManager do
    permission :read, scopes: [:owned]
    permission :update, scopes: [:owned]
    accessible_fields [:name, :type], action: :update
  end
end

class VanPolicy < VehiclePolicy
end

class TruckPolicy < VehiclePolicy
  role :FleetManager do
    permission :delete, scopes: [:owned]
  end
end
```

Vehicle permissions apply to both subtypes without a model resolver. Truck adds its own delete grant using Vehicle's inherited scope. Parent grants are stored once; scope conditions and arguments remain attached to the original grant.

Parent default scopes remain mandatory and combine with child boundaries. Put a shared tenant boundary on Vehicle in tenant applications. Fields inherit per role/action unless the child supplies its own explicit entry. Ancestor lifecycle validators and field resolvers also apply. A child permission adds an alternative grant; it does not revoke broader parent access.

Collection checks enforce subtype restrictions even through `policy_scope(Vehicle)`. The [core inheritance reference](https://github.com/NicolasJJensen/rails_writ/blob/main/docs/reference.md#rule-inheritance-and-sti) covers replacement, field fallback, and explicit model resolution.

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
| `@asset = authorize_proposed!(@asset)` | Checks dirty fields and proposed rules; returns the correctly typed record. |
| `@asset = authorize_proposed!(@asset, attributes: input)` | Assigns input, checks all supplied keys and proposed rules, and returns the record. |

The proposed helper is available automatically, including when Pundit was already included before the adapter loaded. It does not save or replace ordinary `authorize`. It infers `:create`/`:update` from the record; `action:` overrides that inference.

Omitted `attributes:` uses `changed_attribute_names_to_save`. Explicit `{}` supplies no field names; an STI conversion still checks the inheritance column. Unpermitted `ActionController::Parameters` are rejected by Rails assignment.

When the inheritance-column value changes, the helper automatically constructs the requested STI subtype and checks both original and destination authority. Keep the returned record before calling `save!`; the original Ruby instance cannot change its class in place. No special conversion option is needed. See [STI writes](https://github.com/NicolasJJensen/rails_writ/blob/main/docs/advanced-writes.md#changing-an-sti-type).

A proposed failure raises `Writ::Pundit::ProposedAuthorizationError` with `record` and `result`, and attaches final errors to the record. Recover `error.record` in the rescue handler, since a proposed conversion can return a different instance. Missing authority raises ordinary `Pundit::NotAuthorizedError`. See the main README for [HTML, Turbo, and JSON error handling](https://github.com/NicolasJJensen/rails_writ#rendering-errors).

## Permitted attributes

Pundit reads the request parameters and calls the policy hook. The method precedence is:

1. A host-defined action hook such as `permitted_attributes_for_update`.
2. A host-defined generic `permitted_attributes` method.
3. Writ's candidate fields for that action.

A generic method supplies one input list for both create and update:

```ruby
# Inside AssetPolicy
def permitted_attributes
  [:name]
end
```

An action-specific method can adapt the fallback with `super`:

```ruby
# Inside AssetPolicy
def permitted_attributes_for_update
  super - [:description]
end
```

Without a generic host method, `super` uses Writ's candidate fields. With one, it uses that generic list. Writ's `:all` expands to model attribute names, not `permit!`. Create candidates do not run proposed-state validators against an empty record.

Custom parameter hooks do not grant additional authority: `authorize_proposed!` still checks the submitted fields against Writ and validates the resulting record.

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
