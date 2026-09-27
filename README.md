# Writ

Writ provides database-backed roles and permissions for Rails. Define permission defaults in Ruby, assign roles to users, and control which records and fields they can read or change. Each tenant can have its own roles and customized grants.

| Gem | What it provides |
|---|---|
| `rails_writ` | Models, migrations, permission definitions, record filtering, conditions, field permissions, and proposed-state validation. No Pundit dependency. |
| `rails_writ-pundit` | The recommended Rails integration: Pundit policies, policy scopes, generators, and policy loading. Depends on both Writ and Pundit. |

The two gems are developed in this repository and packaged separately. Version 0.2 introduces this split; existing users should read [Upgrading](docs/upgrading.md).

[Installation](#installation) · [Single tenant](#single-tenant-setup) · [Multi-tenant](#multi-tenant-setup) · [Usage](#usage) · [Configuration](#configuration) · [Core without Pundit](#using-the-core-without-pundit)

## Requirements

- Ruby 3.1+ and a compatible Rails / ActiveRecord 7.x or 8.x version.
- PostgreSQL for the generated JSONB migrations.
- Single-column primary keys. Integer, UUID, and custom column names are supported; composite keys are not.

Writ makes authorization decisions. Your application enforces them before returning data or saving changes.

## Installation

For the recommended Pundit integration, add:

```ruby
# Gemfile
gem "rails_writ-pundit", "~> 0.2.0"
```

This installs `rails_writ` and `pundit` too. For direct core usage, add `gem "rails_writ", "~> 0.2.0"` instead and follow [Using the core without Pundit](#using-the-core-without-pundit).

```sh
bundle install
```

Choose **one** setup below. Both assume existing `User` and `Asset` models and tables. `Asset` has `name`, `description`, and `owner_id` attributes; `owner_id` references a user. The multi-tenant setup also needs `Organisation` and `organisation_id` on assets.

These instructions describe the 0.2 packages in this checkout. Until they are published, use local paths in your Gemfile:

```ruby
gem "rails_writ", path: "/path/to/rails_writ"
gem "rails_writ-pundit", path: "/path/to/rails_writ/gems/rails_writ-pundit"
```

## Single-tenant setup

Here roles are global to the application. A `Member` may read, create, and update assets they own.

### 1. Generate models and configuration

```sh
bin/rails generate writ:pundit:install
bin/rails db:migrate
```

The installer adds role membership to `User`, creates authorization tables and models, writes `config/initializers/writ.rb` and `config/writ/permissions.rb`, and creates `ApplicationPolicy < Writ::Pundit::Policy`.

The initializer sets `multi_tenant = false`. Leave `config/writ/permissions.rb` empty when defining all rules in policies.

### 2. Define the context

Use a small context object consistently in policies and direct checks:

```ruby
# app/models/authorization_context.rb
class AuthorizationContext
  attr_reader :user

  def initialize(user:)
    @user = user
  end

  def roles
    user.roles
  end

  def permissions
    user.permissions
  end
end
```

### 3. Define permissions

```ruby
# app/policies/asset_policy.rb
class AssetPolicy < ApplicationPolicy
  allow_missing_default_scope

  scope :owned,
        matches: ->(context, record) { record.owner_id == context.user.id } do |context|
    Asset.where(owner_id: context.user.id)
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

The explicit `allow_missing_default_scope` declaration marks this model as global; scoped models otherwise require a default boundary even in single-tenant mode.

The SQL scope checks saved records. Its `matches:` predicate checks the attributes of a new or changed record. Keep the two equivalent.

### 4. Generate grants and assign a role

For the initial setup, with an empty Writ role table:

```sh
bin/rails writ:generate
bin/rails console
```

Then assign the role to an existing user:

```ruby
user = User.first!
user.roles << Role.find_by!(name: "Member")
context = AuthorizationContext.new(user: user)

Writ::Access.filter(context: context, action: :read, records: Asset.all)
# A relation containing only this user's assets.
```

Generation creates database grants from the definitions. It does not assign roles to users. Do not repeat initial generation after roles exist; use [Adding permissions](#adding-permissions) instead.

## Multi-tenant setup

Here each organisation owns its roles. A user may hold roles in several organisations, but each check uses only their roles in the selected organisation.

### 1. Generate tenant-owned models and configuration

Create the `User` and `Organisation` models before running:

```sh
bin/rails generate writ:pundit:install --multi-tenant --scoping-model=Organisation
bin/rails db:migrate
```

The installer adds role membership to `User` and role ownership to `Organisation`. Keep the generated tenancy settings and add `default_role_name` if you want `Member` as the tenant default:

```ruby
# config/initializers/writ.rb, inside Writ.configure
config.multi_tenant = true
config.default_scoping_model = "Organisation"
config.default_role_name = "Member"
```

The generated `as_roleable(scoping_model: true)` callback initializes permissions when an organisation is created. Setting a default role does **not** assign that role to users.

### 2. Scope the context to the current tenant

```ruby
# app/models/authorization_context.rb
class AuthorizationContext
  attr_reader :user, :organisation

  def initialize(user:, organisation:)
    @user = user
    @organisation = organisation
  end

  def roles
    user.roles.where(organisation_id: organisation.id)
  end

  def permissions
    Permission.where(role_id: roles.select(:id))
  end
end
```

Resolve `organisation` through your application's authenticated tenant-selection flow. The context limits grants to roles the user actually holds in that tenant. Do not use all of `organisation.roles` as the user's permission source.

### 3. Define the record boundary and permissions

```ruby
# app/policies/asset_policy.rb
class AssetPolicy < ApplicationPolicy
  default_scope matches: ->(context, record) {
    record.organisation_id == context.organisation.id
  } do |context|
    Asset.where(organisation_id: context.organisation.id)
  end

  scope :owned,
        matches: ->(context, record) { record.owner_id == context.user.id } do |context|
    Asset.where(owner_id: context.user.id)
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

The context restricts **which grants** apply. The default scope restricts **which records** those grants can reach. Its matcher enforces the same tenant boundary for proposed changes.

### 4. Initialize grants and assign a tenant role

After saving the definitions, new organisations receive defaults through the generated callback. For an **existing organisation with no roles**, run:

```sh
ID=42 MODEL=Organisation bin/rails writ:generate
bin/rails console
```

Assign a role from that organisation:

```ruby
organisation = Organisation.find(42)
user = User.first!
user.roles << organisation.roles.find_by!(name: "Member")
context = AuthorizationContext.new(user: user, organisation: organisation)

Writ::Access.filter(context: context, action: :read, records: Asset.all)
# Only assets owned by this user within this organisation.
```

Do not manually generate defaults again for a newly created organisation whose callback already created roles. To manage automatic generation and later changes, see [Permission management](docs/permission-management.md).

## Connect Pundit to Rails

Include Pundit's controller helpers and supply the context. Your authentication system must provide `current_user`.

Single tenant:

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Pundit::Authorization

  def pundit_user
    AuthorizationContext.new(user: current_user)
  end
end
```

Multi-tenant applications use the same controller integration with this method instead. `current_organisation` is the tenant selected and checked by your application:

```ruby
def pundit_user
  AuthorizationContext.new(user: current_user, organisation: current_organisation)
end
```

Authenticate before checking permissions. Each request must use the correct context; when changing users or tenants within the same controller instance, reset Pundit's cached context with `pundit_reset!`.

## How permissions work

| Concept | Meaning |
|---|---|
| Role | A named group of permissions assigned to a user. |
| Permission / grant | An action on a model, optionally restricted by scopes and conditions. |
| Scope | An ActiveRecord relation selecting permitted records. |
| Condition | A Ruby check that decides whether a grant applies to the context. |
| Matcher | A Ruby predicate checking proposed attributes against a scope's rule. |

Scopes within one grant intersect. Separate valid grants combine to allow access. Default scopes constrain every grant. Rejecting one grant does not override a different valid grant.

Ruby declarations define defaults; database grants determine the effective permissions. Editing a declaration does not overwrite customized database grants.

## Usage

### Authorize and filter saved records

With Pundit, use `authorize` for one record and `policy_scope` for a collection:

```ruby
# Inside a controller using Pundit::Authorization
assets = policy_scope(Asset).order(:name).limit(20)
asset = Asset.find(params[:id])
authorize asset, :show?
```

`show?`, `index?`, and `read?` map to `:read`; `new?` and `create?` to `:create`; `edit?` and `update?` to `:update`; `destroy?` and `delete?` to `:delete`.

Direct checks work with either gem setup:

```ruby
result = Writ::Access.authorization(subject: asset, action: :read, context: context)
result.allowed?      # true or false
result.reason        # e.g. :granted or :no_grants
result.denied_grants # per-grant denial details

assets = Writ::Access.filter(records: Asset.all, action: :read, context: context)
```

Passing a model class checks grant availability, not access to a particular record. Filter before pagination. Authorizing a collection checks **all records before pagination**; it does not remove denied rows.

### Enforce field permissions

Readable/writable fields return `:all` or an array of string names. Action authorization and field enforcement are separate.

After authorizing a read, serialize only allowed fields:

```ruby
fields = Writ::Access.readable_fields(context: context, record: asset)
output = fields == :all ? asset.as_json : asset.as_json(only: fields)
```

For the example policy, read fields are `name` and `description`; update fields contain only `name`. Missing declarations default to `:all`. Set `config.field_default = []` for opt-in fields.

Omitting `action:` from `accessible_fields` declares the same list for all four CRUD actions, not custom actions. A later declaration replaces the earlier list for that action. Across effective roles, field lists combine; any contributing `:all` makes the combined result unrestricted.

For a page of records, batch the lookup:

```ruby
assets = Writ::Access.filter(context: context, action: :read, records: Asset.all).limit(50).to_a
fields_by_asset = Writ::Access.fields_for_many(context: context, action: :read, records: assets)
# { asset => ["name", "description"] }; denied records map to [].
```

### Create records

Ownership and tenant attributes come from the context, not request parameters. Add the matching private helper to your controller.

Single tenant:

```ruby
private

def build_asset(context)
  Asset.new(owner_id: context.user.id)
end
```

Multi-tenant:

```ruby
private

def build_asset(context)
  Asset.new(owner_id: context.user.id, organisation_id: context.organisation.id)
end
```

Use this public action above the controller's `private` section in either mode:

```ruby
def create
  context = pundit_user
  asset = build_asset(context)
  authorize asset, :create?

  attributes = params.require(:asset).permit(:name, :description).to_h
  asset.assign_attributes(attributes)
  fields = Writ::Access.writable_fields(context: context, record: asset, action: :create)
  unless fields == :all || (attributes.keys - fields).empty?
    raise Pundit::NotAuthorizedError, "Fields are not writable"
  end

  result = Writ::Access.validation(subject: asset, action: :create, context: context)
  raise Pundit::NotAuthorizedError unless result.allowed?

  asset.save!
  head :created
end
```

`create?` checks grant availability and conditions. `validation` checks the proposed attributes through matchers and creation validators. A SQL scope is not automatically translated into a Ruby matcher.

### Update records

Authorize the saved record and submitted fields before assignment, then validate proposed attributes before saving:

```ruby
def update
  context = pundit_user
  asset = Asset.find(params[:id])
  attributes = params.require(:asset).permit(:name, :description).to_h

  asset.with_lock do
    authorize asset, :update?
    fields = Writ::Access.writable_fields(context: context, record: asset, action: :update)
    unless fields == :all || (attributes.keys - fields).empty?
      raise Pundit::NotAuthorizedError, "Fields are not writable"
    end

    asset.assign_attributes(attributes)
    result = Writ::Access.validation(subject: asset, action: :update, context: context)
    raise Pundit::NotAuthorizedError unless result.allowed?
    asset.save!
  end
  head :no_content
end
```

This works with either context setup. In the example policy, submitting `description` for an update is denied. `with_lock` reloads and locks the saved record before assignment. See [Advanced write flows](docs/advanced-writes.md) for related-record locks, nested writes, and callbacks.

### Conditions and custom actions

Define the condition before attaching it to a permission:

```ruby
# Inside AssetPolicy
condition :business_hours do |_context|
  (9...17).cover?(Time.current.hour)
end

role :Member do
  permission :publish, scopes: [:owned], conditions: [:business_hours]
end

def publish?
  permitted?(:publish)
end
```

Generate this new action for existing roles using the migration below. Then `authorize asset, :publish?` checks ownership, the current time, and the tenant boundary in a multi-tenant policy. Custom predicates are explicit; misspelled predicates raise `NoMethodError`.

### Adding permissions

After adding a model/action to your definitions, apply it to existing roles. Existing grants and customized fields are preserved.

Single tenant, in a Rails runner or data migration:

```ruby
Writ::Generator.add_permissions(permissions: [{ model: Asset, action: :publish }])
```

Multi-tenant:

```ruby
Organisation.find_each do |organisation|
  Writ::Generator.add_permissions(
    organisation, permissions: [{ model: Asset, action: :publish }]
  )
end
```

This adds missing model/action grants. Changing scopes on an existing action requires an explicit application migration. See [Permission management](docs/permission-management.md) for cleanup and argument changes.

## Configuration

Keep settings in `config/initializers/writ.rb`. Put model-dependent core rules in `config/writ/*.rb`; these run after initialization and on reload. With the add-on, rules can instead live in `app/policies`. Do not declare the same rule in both places.

### Common settings

```ruby
Writ.configure do |config|
  config.multi_tenant = false # true for tenant-owned roles
  config.field_default = []
  config.on_missing_condition = :raise
  config.on_condition_error = :raise
  config.on_invalid_scope_arguments = :raise
  config.on_invalid_condition_arguments = :raise
  config.on_missing_default_scope = :raise
  config.on_missing_matcher = :raise
end
```

Keep the generated authorization model settings in that initializer too.

| Setting | Default | Purpose |
|---|---|---|
| `multi_tenant` | Installer writes `false` or `true` | Chooses global or tenant-owned role generation. Without an explicit `false`, global generation is rejected. |
| `default_scoping_model` | Installer writes the tenant class in tenant mode | Tenant model used by the generation task. |
| `default_role_name` | `"Default Role"` in Rails | Marks a generated tenant role as the default; does not assign users. |
| `field_default` | `:all` | Fields allowed when an action has no field declaration. |
| `permission_source`, `role_source` | `context.permissions`, `context.roles` | Relations used to obtain the current actor's grants and roles. |

### Error handling

All six `on_*` settings above default to `:raise`.

| Settings | Other modes | Meaning |
|---|---|---|
| Missing condition, condition error, invalid scope/condition arguments | `:deny` | Exclude the affected grant. Other valid grants still apply. |
| Missing default scope or matcher | `:warning`, `:skip` | Continue without the missing constraint, with or without a warning. |

Keep missing boundaries visible as errors unless your application deliberately accepts their absence. Models with record scopes require a default scope or an explicit model exemption in either tenancy mode.

A deliberately global model can be exempted without disabling the check for others:

```ruby
# config/writ/countries.rb; Country has a boolean published column.
Writ.configure do
  allow_missing_default_scope model: Country
  scope :published, model: Country do |_context|
    Country.where(published: true)
  end
end
```

### Custom context sources

The two setup examples implement `roles` and `permissions` directly. If your application already exposes equivalent methods with different names, configure callbacks to return those relations. For example, a context with `user` and `organisation` can be used without defining the relation methods:

```ruby
Writ.configure do |config|
  config.role_source = ->(context) {
    context.user.roles.where(organisation_id: context.organisation.id)
  }
  config.permission_source = ->(context) {
    roles = context.user.roles.where(organisation_id: context.organisation.id)
    Permission.where(role_id: roles.select(:id))
  }
end
```

For single-tenant contexts the equivalent callbacks return `context.user.roles` and `context.user.permissions`. Always use the user's assigned roles, restricted to the current tenant where applicable.

### Additional attribute checks

Use model-specific validators for rules that supplement scope matchers:

```ruby
# config/writ/asset_validators.rb; applies with or without Pundit.
Writ.configure do
  creation_validator model: Asset do |context:, record:|
    record.owner_id == context.user.id && record.name.present?
  end

  update_validator model: Asset do |context:, record:|
    record.name.present?
  end
end
```

Both tenancy setups use these validators; the multi-tenant default matcher also enforces `organisation_id`. Global validators run before model-specific validators, and every applicable validator must pass. They run only in `Writ::Access.validation` for their matching create/update action.

## Using the core without Pundit

Install only `rails_writ`. The core does not load Pundit, define policy classes, or scan `app/policies`.

### Generate either tenancy mode

Single tenant:

```sh
bin/rails generate writ:install
bin/rails db:migrate
```

Multi-tenant, with existing `User` and `Organisation` models:

```sh
bin/rails generate writ:install --multi-tenant --scoping-model=Organisation
bin/rails db:migrate
```

Use the matching `AuthorizationContext` shown in the setup sections above. Keep the generated initializer; replace the contents of `config/writ/permissions.rb` with:

```ruby
Writ.configure do
  allow_missing_default_scope model: Asset

  scope :owned, model: Asset,
        matches: ->(context, record) { record.owner_id == context.user.id } do |context|
    Asset.where(owner_id: context.user.id)
  end

  with_options model: Asset, role: :Member do
    permission :read, scopes: [:owned]
    permission :create, scopes: [:owned]
    permission :update, scopes: [:owned]
    accessible_fields [:name, :description], action: :read
    accessible_fields [:name, :description], action: :create
    accessible_fields [:name], action: :update
  end
end
```

For **multi-tenant** use, remove `allow_missing_default_scope model: Asset` and add this default scope inside that `Writ.configure` block:

```ruby
default_scope model: Asset, matches: ->(context, record) {
  record.organisation_id == context.organisation.id
} do |context|
  Asset.where(organisation_id: context.organisation.id)
end
```

Generate defaults and assign roles exactly as in the corresponding setup section: `bin/rails writ:generate` for global roles; `ID=42 MODEL=Organisation bin/rails writ:generate` for an existing tenant with no roles. New tenants use the generated callback.

### Enforce decisions directly

Use an application-owned exception or response for denial; Pundit is not required:

```ruby
# app/errors/access_denied.rb
class AccessDenied < StandardError; end
```

```ruby
# Inside an application service; context is the matching AuthorizationContext.
asset.with_lock do
  result = Writ::Access.authorization(subject: asset, action: :update, context: context)
  raise AccessDenied unless result.allowed?

  fields = Writ::Access.writable_fields(context: context, record: asset, action: :update)
  attributes = attributes.stringify_keys
  raise AccessDenied unless fields == :all || (attributes.keys - fields).empty?

  asset.assign_attributes(attributes)
  result = Writ::Access.validation(subject: asset, action: :update, context: context)
  raise AccessDenied unless result.allowed?
  asset.save!
end
```

For creation, use the matching `build_asset(context)` helper from [Create records](#create-records), then check the proposed record directly:

```ruby
asset = build_asset(context)
input = attributes.stringify_keys
raise AccessDenied unless (input.keys - %w[name description]).empty?
asset.assign_attributes(input)

fields = Writ::Access.writable_fields(context: context, record: asset, action: :create)
raise AccessDenied unless fields == :all || (input.keys - fields).empty?

result = Writ::Access.validation(subject: asset, action: :create, context: context)
raise AccessDenied unless result.allowed?
asset.save!
```

This works for both tenancy modes with the corresponding helper and context. Filtering and readable fields use the same `Writ::Access` calls shown above.

## Advanced guides

- [API and advanced configuration](docs/reference.md): query contracts, custom models/keys, rule arguments, field resolvers, STI, and reloading.
- [Permission management](docs/permission-management.md): generation, migrations, tenant arguments, and cleanup.
- [Advanced write flows](docs/advanced-writes.md): nested records, callbacks, concurrency, and transitions.
- [Performance and instrumentation](docs/performance.md): batch costs, notifications, and profiling.
- [Upgrading](docs/upgrading.md): the gem split and schema checks for older installations.
- [Pundit adapter](https://github.com/NicolasJJensen/rails_writ/tree/main/gems/rails_writ-pundit): adapter-specific setup and policy behavior.

## Development and contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for PostgreSQL setup, testing both gems, and packaging. Issues and pull requests are welcome on [GitHub](https://github.com/NicolasJJensen/rails_writ). User-visible changes are recorded in the [changelog](CHANGELOG.md).

## License

Both gems use the [MIT License](LICENSE.txt).
