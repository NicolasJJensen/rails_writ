# Writ for Pundit

`rails_writ-pundit` connects Writ's database-backed permissions to Pundit. It provides `Writ::Pundit::Policy`, policy generators, and Rails policy loading. Installing it also installs `rails_writ` and `pundit`.

The [main Writ README](https://github.com/NicolasJJensen/rails_writ#readme) contains complete single-tenant and multi-tenant application examples, configuration, field enforcement, and create/update flows. This README covers the adapter itself.

## Install

```ruby
# Gemfile
gem "rails_writ-pundit"
```

```sh
bundle install
```

Ruby 3.1+, a compatible Rails 7.x/8.x version, and PostgreSQL are required for the generated setup.

## Setup

If Writ's core models and configuration are already installed, add only the policy base:

```sh
bin/rails generate writ:pundit:application_policy
```

For a fresh application, the combined installer creates the core setup and policy base together. Use the ordinary installer for shared roles:

```sh
bin/rails generate writ:pundit:install
bin/rails db:migrate
```

For organisation-owned roles, use the tenant options:

```sh
bin/rails generate writ:pundit:install --multi-tenant --scoping-model=Organisation
bin/rails db:migrate
```

Both create:

```ruby
# app/policies/application_policy.rb
class ApplicationPolicy < Writ::Pundit::Policy
end
```

The [main README](https://github.com/NicolasJJensen/rails_writ#installation) shows every generated file, the migration changes, and how to define and assign roles in either tenancy mode.

## Policies

If your rules already live in `config/writ/*.rb`, an empty policy connects them to Pundit:

```ruby
# app/policies/asset_policy.rb
class AssetPolicy < ApplicationPolicy
end
```

Alternatively, define the rules in the policy. This example gives Members read access to their own assets:

```ruby
# app/policies/asset_policy.rb
class AssetPolicy < ApplicationPolicy
  allow_missing_default_scope

  scope :owned, matches: ->(user, record) { record.owner_id == user.id } do |user|
    Asset.where(owner_id: user.id)
  end

  role :Member do
    permission :read, scopes: [:owned]
    accessible_fields [:name], action: :read
  end
end
```

> `Asset`, `owner_id`, and `name` are application code and attributes. The policy infers its model from `AssetPolicy`. Move these rules out of `config/writ` when declaring them here.

For tenant-owned assets, replace `allow_missing_default_scope` with:

```ruby
# Inside AssetPolicy
default_scope matches: ->(_user, record) {
  record.organisation_id == Current.organisation.id
} do
  Asset.where(organisation_id: Current.organisation.id)
end
```

This uses the main README's [multi-tenant setup](https://github.com/NicolasJJensen/rails_writ#multi-tenant-access), including its tenant-filtered role and permission sources. `Current.organisation` belongs to the application. Keep the ownership scope and role declarations unchanged.

## Controller integration

Pundit uses `current_user` automatically:

```ruby
class ApplicationController < ActionController::Base
  include Pundit::Authorization
end
```

Use the normal entry points:

```ruby
assets = policy_scope(Asset).order(:name).limit(20)
asset = Asset.find(params[:id])
authorize asset, :show?
```

This works in both tenancy modes with the matching Writ configuration. There is no required context wrapper. If your application uses a custom Pundit context, return it from `pundit_user` and configure Writ's sources and rule blocks to use that object, as described in the [custom context example](https://github.com/NicolasJJensen/rails_writ#passing-a-custom-context).

The policy scope filters on `:read`. `authorize` raises `Pundit::NotAuthorizedError` on denial; configure your application's response handling. If the user or tenant changes within a controller instance, call `pundit_reset!` before reusing Pundit's helpers.

## Policy behavior

| Predicate | Writ action |
|---|---|
| `index?`, `show?`, `read?` | `:read` |
| `new?`, `create?` | `:create` |
| `edit?`, `update?` | `:update` |
| `destroy?`, `delete?` | `:delete` |

Predicates use `Writ::Access.authorization`. They do **not** run proposed-state validation or enforce field lists. For creates and updates, also enforce writable fields and call `Writ::Access.validation` before saving. Complete implementations are in the main README.

Custom actions require explicit methods:

```ruby
# Inside AssetPolicy
role :Member do
  permission :publish
end

def publish?
  permitted?(:publish)
end
```

In multi-tenant mode the default scope still applies. In a single-tenant application add any ownership scope required by the action. Migrate the new action into existing roles before using it.

The generator can emit custom predicates:

```sh
bin/rails generate writ:pundit:policy Asset --roles Member --actions read publish
```

Unknown predicates raise `NoMethodError`. Generated action names must not collide with CRUD aliases (`index`, `show`, `new`, `edit`, `destroy`), `permitted`, or inherited Ruby predicates such as `respond_to` and `is_a`.

## Shared conditions

You do not need an empty Conditions concern. Define a shared condition on the base policy before requiring it:

```ruby
class ApplicationPolicy < Writ::Pundit::Policy
  condition :business_hours do |_context|
    (9...17).cover?(Time.current.hour)
  end
  requires_conditions :business_hours
end
```

This attaches the condition to descendant permissions. `requires_conditions` must precede local permission declarations. Alternatively, `with_conditions :business_hours do ... end` applies only to its enclosed declarations. Requirements are additive and deduplicated; conflicting argument declarations raise.

## Loading and customization

The adapter loads `app/policies` during Writ registry rebuilds, after core `config/writ/*.rb` definitions. Rails reloads rebuild both against current model classes. Avoid declaring the same scope/condition in both places.

Use `Writ::Pundit::PolicyHelpers` directly only when implementing your own policy base. The ready-made `Writ::Pundit::Policy` supplies predicates and `Scope#resolve`.

For custom actor/tenant names, namespaces, or keys, pass the same options accepted by `writ:install` to `writ:pundit:install`. The adapter does not change the core schema or tenant ownership rules.

Review an existing customized `ApplicationPolicy` before replacing it.

## Development and license

Both packages are tested from the repository root; see its contribution guide for the commands. The adapter uses the [MIT License](LICENSE.txt).
