# Writ for Pundit

`rails_writ-pundit` connects Writ's database-backed permissions to Pundit. It provides `Writ::Pundit::Policy`, policy generators, and Rails policy loading. Installing it also installs `rails_writ` and `pundit`.

The [main Writ README](https://github.com/NicolasJJensen/rails_writ#readme) contains complete single-tenant and multi-tenant application examples, configuration, field enforcement, and create/update flows. This README covers the adapter itself.

## Install

```ruby
# Gemfile
gem "rails_writ-pundit", "~> 0.2.0"
```

```sh
bundle install
```

These are the 0.2 packages; until published, use the local paths documented in the main README. Ruby 3.1+, a compatible Rails 7.x/8.x version, and PostgreSQL are required for the generated setup.

## Single-tenant setup

With an existing `User` model:

```sh
bin/rails generate writ:pundit:install
bin/rails db:migrate
bin/rails generate writ:pundit:policy Asset --roles Member --actions read
```

The installer creates core models/configuration and this base policy:

```ruby
# app/policies/application_policy.rb
class ApplicationPolicy < Writ::Pundit::Policy
end
```

For an existing `Asset` with `owner_id`, replace the generated Asset policy with:

```ruby
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

Generate global defaults once, while the role table is empty:

```sh
bin/rails writ:generate
bin/rails console
```

```ruby
user = User.first!
user.roles << Role.find_by!(name: "Member")
Pundit.policy_scope!(user, Asset)
# Only assets owned by this user.
```

## Multi-tenant setup

With existing `User`, `Organisation`, and `Asset` models, where Asset has `organisation_id`:

```sh
bin/rails generate writ:pundit:install --multi-tenant --scoping-model=Organisation
bin/rails db:migrate
```

Use a context that exposes only the user's roles within the selected organisation:

```ruby
# app/models/authorization_context.rb
class AuthorizationContext
  attr_reader :user, :organisation

  def initialize(user:, organisation:)
    @user, @organisation = user, organisation
  end

  def roles
    user.roles.where(organisation_id: organisation.id)
  end

  def permissions
    Permission.where(role_id: roles.select(:id))
  end
end
```

```ruby
# app/policies/asset_policy.rb
class AssetPolicy < ApplicationPolicy
  default_scope matches: ->(context, record) {
    record.organisation_id == context.organisation.id
  } do |context|
    Asset.where(organisation_id: context.organisation.id)
  end

  role :Member do
    permission :read
    accessible_fields [:name], action: :read
  end
end
```

Here Members may read assets in their organisation. Add an ownership scope when that additional restriction is required.

New organisations receive defaults through the generated callback. For an existing organisation with no roles:

```sh
ID=42 MODEL=Organisation bin/rails writ:generate
bin/rails console
```

```ruby
organisation = Organisation.find(42)
user = User.first!
user.roles << organisation.roles.find_by!(name: "Member")
context = AuthorizationContext.new(user: user, organisation: organisation)
Pundit.policy_scope!(context, Asset)
```

The application must authenticate the user and select an authorized tenant. Do not pass all tenant roles as the user's permission source. Default generation never assigns user membership.

## Controller integration

For the single-tenant example above, Pundit uses `current_user` automatically:

```ruby
class ApplicationController < ActionController::Base
  include Pundit::Authorization
end
```

For the multi-tenant example, override its context. `current_organisation` must come from your application's tenant-selection flow:

```ruby
class ApplicationController < ActionController::Base
  include Pundit::Authorization

  def pundit_user
    AuthorizationContext.new(user: current_user, organisation: current_organisation)
  end
end
```

Then use normal Pundit entry points:

```ruby
assets = policy_scope(Asset).order(:name).limit(20)
asset = Asset.find(params[:id])
authorize asset, :show?
```

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

If core is already installed, generate only the base policy:

```sh
bin/rails generate writ:pundit:application_policy
```

Review an existing customized `ApplicationPolicy` before replacing it. See the main repository's upgrade guide for migrating 0.1 installations.

## Development and license

Both packages are tested from the repository root; see its contribution guide for the commands. The adapter uses the [MIT License](LICENSE.txt).
