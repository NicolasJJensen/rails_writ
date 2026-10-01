# Writ

Writ adds database-backed roles and permissions to Rails. Give users roles such as Member or Editor, define what each role can do, and restrict access to particular records or fields. In a multi-tenant application, each organisation owns its roles and can customize its permissions.

The `rails_writ` gem provides the permission system and an API for checking access. The optional `rails_writ-pundit` gem connects those checks to Pundit's policies and controller helpers.

## Contents

- [Installation](#installation)
- [Roles and permissions](#roles-and-permissions)
- [Scopes](#scopes)
- [Multi-tenant access](#multi-tenant-access)
- [Assigning roles](#assigning-roles)
- [Checking access](#checking-access)
- [Field permissions](#field-permissions)
- [Creating and updating records](#creating-and-updating-records)
- [Pundit integration](#pundit-integration)
- [More complex rules](#more-complex-rules)
- [Configuration](#configuration)
- [Existing applications](#existing-applications)
- [Advanced guides](#advanced-guides)
- [Development and contributing](#development-and-contributing)
- [License](#license)

## Installation

Writ requires Ruby 3.1+, Rails / ActiveRecord 7.x or 8.x, and PostgreSQL.

```ruby
# Gemfile
gem "rails_writ"
```

```sh
bundle install
```

For an application with a shared set of roles:

```sh
bin/rails generate writ:install
```

For an application where each organisation owns its roles:

```sh
bin/rails generate writ:install --multi-tenant --scoping-model=Organisation
```

Then apply the generated migrations:

```sh
bin/rails db:migrate
```

### Generated files

Both installation modes create the same core files. Migration filenames have timestamp prefixes:

```text
app/models/
  role.rb
  permission.rb
  scope.rb
  permission_scope.rb
  condition.rb
  permission_condition.rb
config/
  initializers/writ.rb
  writ/permissions.rb
db/migrate/
  ..._create_roles.rb
  ..._create_permissions.rb
  ..._create_scopes.rb
  ..._create_permission_scopes.rb
  ..._create_conditions.rb
  ..._create_permission_conditions.rb
  ..._create_join_table_roles_users.rb
```

The installer adds role membership to `User`:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  include Writ::Roleable
  as_roleable
end
```

This provides `user.roles` and `user.permissions`. The generated models store the authorization data:

| Model / table | Stores |
|---|---|
| `Role` / `roles` | Role name, description, color, and field permissions. |
| `Permission` / `permissions` | An action on a model, belonging to a role. |
| `Scope` / `scopes` | Names of record filters defined in Ruby. |
| `PermissionScope` / `permission_scopes` | Filters attached to a permission, with any arguments. |
| `Condition` / `conditions` | Names of checks defined in Ruby. |
| `PermissionCondition` / `permission_conditions` | Checks attached to a permission, with any arguments. |
| `roles_users` | User-to-role assignments; a user can hold several roles. |

<details>
<summary>Generated migrations</summary>

These are the single-tenant migrations with the default model names, shown for Rails 7. The generator uses your Rails migration version.

```ruby
# db/migrate/..._create_roles.rb
class CreateRoles < ActiveRecord::Migration[7.0]
  def change
    create_table :roles do |t|
      t.string :name, null: false
      t.string :description
      t.string :color
      t.jsonb :accessible_fields, default: {}, null: false
      t.jsonb :generated_fields, default: {}, null: false

      t.timestamps
    end

    add_index :roles, :name, unique: true, name: "roles_name"
  end
end
```

```ruby
# db/migrate/..._create_permissions.rb
class CreatePermissions < ActiveRecord::Migration[7.0]
  def change
    create_table :permissions do |t|
      t.references :role, index: { name: "permissions_role" }, null: false, foreign_key: { to_table: :roles }
      t.string :model, index: { name: "permissions_model" }, null: false
      t.string :action, null: false
      t.string :generated_signature

      t.timestamps
    end

    add_index :permissions, [:action, :model], name: "permissions_action_model"
    add_index :permissions, [:role_id, :action, :model], name: "permissions_role_action_model"
  end
end
```

```ruby
# db/migrate/..._create_scopes.rb
class CreateScopes < ActiveRecord::Migration[7.0]
  def change
    create_table :scopes do |t|
      t.string :model, null: false
      t.string :name, null: false

      t.timestamps
    end

    add_index :scopes, [:model, :name], unique: true, name: "scopes_model_name"
  end
end
```

```ruby
# db/migrate/..._create_permission_scopes.rb
class CreatePermissionScopes < ActiveRecord::Migration[7.0]
  def change
    create_table :permission_scopes do |t|
      t.references :permission, index: { name: "permission_scopes_permission" }, null: false, foreign_key: { to_table: :permissions }
      t.references :scope, index: { name: "permission_scopes_scope" }, null: false, foreign_key: { to_table: :scopes }
      t.jsonb :arguments, default: {}, null: false

      t.timestamps
    end

    add_index :permission_scopes, [:permission_id, :scope_id], unique: true, name: "permission_scopes_pair"
  end
end
```

```ruby
# db/migrate/..._create_conditions.rb
class CreateConditions < ActiveRecord::Migration[7.0]
  def change
    create_table :conditions do |t|
      t.string :name, null: false

      t.timestamps
    end

    add_index :conditions, :name, unique: true, name: "conditions_name"
  end
end
```

```ruby
# db/migrate/..._create_permission_conditions.rb
class CreatePermissionConditions < ActiveRecord::Migration[7.0]
  def change
    create_table :permission_conditions do |t|
      t.references :permission, index: { name: "permission_conditions_permission" }, null: false, foreign_key: { to_table: :permissions }
      t.references :condition, index: { name: "permission_conditions_condition" }, null: false, foreign_key: { to_table: :conditions }
      t.jsonb :arguments, default: {}, null: false

      t.timestamps
    end

    add_index :permission_conditions, [:permission_id, :condition_id], unique: true, name: "permission_conditions_pair"
  end
end
```

```ruby
# db/migrate/..._create_join_table_roles_users.rb
class CreateJoinTableRolesUsers < ActiveRecord::Migration[7.0]
  def change
    create_table :roles_users, id: false do |t|
      t.references :role, null: false, index: false, foreign_key: { to_table: :roles }
      t.bigint :user_id, null: false
      t.index [:user_id, :role_id], unique: true, name: "roles_users_actor_role"
      t.index [:role_id, :user_id], name: "roles_users_role_actor"
    end

    add_foreign_key :roles_users, :users,
                    column: :user_id, primary_key: "id"
  end
end
```

</details>

The generated initializer selects the tenancy mode and authorization models. Its active settings for a single-tenant application are:

```ruby
# config/initializers/writ.rb
Writ.configure do |config|
  config.multi_tenant = false
  config.role_class = "Role"
  config.permission_class = "Permission"
  config.scope_class = "Scope"
  config.permission_scope_class = "PermissionScope"
  config.condition_class = "Condition"
  config.permission_condition_class = "PermissionCondition"
end
```

The installer also creates an empty block for your permission definitions:

```ruby
# config/writ/permissions.rb
Writ.configure do
end
```

Keep settings in the initializer and model-dependent rules in `config/writ/*.rb`. Rails loads those rules after initialization and rebuilds them when application code reloads.

### Multi-tenant differences

With `--multi-tenant --scoping-model=Organisation`, the installer also adds:

```ruby
# app/models/organisation.rb
class Organisation < ApplicationRecord
  include Writ::Roleable
  as_roleable(scoping_model: true)
end
```

This gives each organisation its own `roles` and `permissions`, and generates those roles from your definitions when an organisation is created.

The initializer uses these tenancy settings in place of `multi_tenant = false`:

```ruby
Writ.configure do |config|
  config.multi_tenant = true
  config.default_scoping_model = "Organisation"
end
```

The schema changes are limited to role ownership and a reference for the organisation's default role:

```ruby
# In CreateRoles#change, inside create_table :roles:
t.references :organisation, type: :bigint, null: false,
             index: { name: "roles_tenant" },
             foreign_key: { to_table: :organisations, primary_key: "id" }

# Replaces the unique index on role name alone:
add_index :roles, [:organisation_id, :name], unique: true,
          name: "roles_tenant_name"
```

```ruby
# db/migrate/..._add_default_role_to_organisations.rb
class AddDefaultRoleToOrganisations < ActiveRecord::Migration[7.0]
  def change
    add_reference :organisations, :default_role,
                  foreign_key: { to_table: :roles, deferrable: :deferred }
  end
end
```

The generated `Role` belongs to `Organisation`; `Permission` reaches its organisation through its role. The `default_role_id` column backs `organisation.default_user_role`, explained under [Default roles](#default-roles).

> `User`, `Organisation`, and the records your application protects are application models. Writ adds the authorization models and associations; your application owns its tenant relationships, such as `Asset.organisation_id`. Pass `--roleable-model=Account` to use a different user model. See [custom models and keys](docs/reference.md#custom-models-namespaces-and-keys) for other generator options.

## Roles and permissions

A **role** groups permissions under a name, such as Member. A **permission** allows an action on a model, such as reading an Asset. Assigning the Member role to a user gives that user the role's permissions:

```text
User → Member role → read Asset permission
```

Define the initial permissions in Ruby:

```ruby
# config/writ/permissions.rb
Writ.configure do
  permission :read, model: Asset, role: :Member
end
```

Here, Members can read every Asset. Users without a matching permission are denied. The standard actions are `:read`, `:create`, `:update`, and `:delete`; you can also define application actions such as `:publish`.

The definitions describe the initial roles and permissions to save in the database. Once saved, those permissions can be customized per role, or per organisation in a multi-tenant application. Access checks use the saved permissions.

The next sections add record restrictions to this example. Save your chosen definitions before [generating and assigning roles](#assigning-roles). For an application that already has stored roles, use [Updating existing permissions](#updating-existing-permissions) to apply definition changes.

## Scopes

A **scope** limits a permission to a set of records. For example, a published scope allows Members to read published assets:

```ruby
# config/writ/permissions.rb
Writ.configure do
  allow_missing_default_scope model: Asset

  scope :published, model: Asset do
    Asset.where(published: true)
  end

  permission :read, model: Asset, role: :Member, scopes: [:published]
end
```

> `Asset` and its `published` column belong to your application. Writ's `scope` registers the filter; the block returns an ordinary ActiveRecord relation.

This replaces the earlier unrestricted read permission. A permission without `scopes:` still allows all records within any default scope.

A **default scope** is a filter applied to every permission for a model. Writ requires models with scopes to either declare that filter or explicitly opt out. Here, `allow_missing_default_scope` means Asset has no shared boundary. For tenant-owned assets, replace that exemption with the organisation filter shown below. Writ's `default_scope` is separate from ActiveRecord's model-level `default_scope`.

### Using the current user

Rules often need to know who is making the request. Writ calls the object supplied to an access check its **context**. Normally this is simply the current user:

```ruby
Writ::Access.authorization(subject: asset, action: :read, context: current_user)
```

Writ reads `roles` and `permissions` from that object and passes it to scope and condition blocks. The generated `User` integration already supplies both associations; no context class is required.

To restrict Members to their own assets, replace the published example with:

```ruby
# config/writ/permissions.rb
Writ.configure do
  allow_missing_default_scope model: Asset

  scope :owned, model: Asset do |user|
    Asset.where(owner_id: user.id)
  end

  permission :read, model: Asset, role: :Member, scopes: [:owned]
end
```

> `owner_id` is an application column referencing the user who owns an asset. The block parameter is named `user` because these examples pass a User as `context:`.

Multiple scopes on one permission must all match. If a user has several permissions for an action, any one matching permission can allow access. A default scope constrains all of them.

## Multi-tenant access

The same role and permission definitions work for both tenancy modes. Tenant-owned data needs two additional restrictions: use only the user's roles in the selected organisation, and return only that organisation's records.

This example keeps passing `current_user` to Writ and uses `Current.organisation` for the selected tenant:

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :organisation
end
```

> `Current` is application code, not a Writ requirement. Set `Current.organisation` through your application's authenticated tenant-selection flow before checking access. If your application already stores the selected tenant elsewhere, use that instead.

Configure the sources for the user's roles and permissions:

```ruby
# config/initializers/writ.rb; add to the generated settings.
Writ.configure do |config|
  config.role_source = ->(user) {
    user.roles.where(organisation_id: Current.organisation.id)
  }
  config.permission_source = ->(user) {
    roles = user.roles.where(organisation_id: Current.organisation.id)
    Permission.where(role_id: roles.select(:id))
  }
end
```

In `config/writ/permissions.rb`, replace `allow_missing_default_scope model: Asset` with this declaration inside the existing `Writ.configure` block:

```ruby
default_scope model: Asset do
  Asset.where(organisation_id: Current.organisation.id)
end
```

Keep the `:owned` scope and permission unchanged. Members can now read assets they own **within the selected organisation**. Holding a role in another organisation does not grant access here.

The generator configures tenant-owned roles; it cannot infer the tenant relationship on every application model. Add a default scope for each protected tenant-owned model. A deliberately shared model, such as a global Country catalog, can use `allow_missing_default_scope` instead.

## Assigning roles

After defining permissions, create the initial roles.

In a single-tenant application, run:

```sh
bin/rails writ:generate
```

In a multi-tenant application, new organisations receive their roles through the generated callback:

```ruby
organisation = Organisation.create!(name: "Acme")
organisation.roles.find_by!(name: "Member")
```

> `name` is an example application attribute. Create organisations through your normal application flow with whatever attributes it requires.

Assign a role when your application enrolls a user. For shared roles:

```ruby
user.roles << Role.find_by!(name: "Member")
```

For organisation-owned roles:

```ruby
user.roles << organisation.roles.find_by!(name: "Member")
```

A user can have several roles. Permissions from those roles combine, using the tenant restrictions above when configured.

### Default roles

An organisation's **default role** is the role your application intends to give new members. Writ stores that choice as `organisation.default_user_role`, so your invitation or sign-up flow can use it without hard-coding a role lookup.

To select Member when generating a new organisation's roles, add this setting before creating organisations:

```ruby
# config/initializers/writ.rb
Writ.configure do |config|
  config.default_role_name = "Member"
end
```

The name must match a role in your definitions. Your enrollment code then assigns it:

```ruby
user.roles << organisation.default_user_role
```

Writ records the default choice during role generation; your application controls when users join and receive that role. The Rails setting defaults to `"Default Role"`; if no generated role has that name, no default role is selected. Single-tenant applications can assign their chosen role directly with `Role.find_by!`, as above.

## Checking access

For one saved record, ask whether the user may perform an action:

```ruby
result = Writ::Access.authorization(subject: asset, action: :read, context: user)
result.allowed? # true or false
result.reason   # explains the decision
```

For a list, filter the relation before ordering or pagination:

```ruby
assets = Writ::Access.filter(records: Asset.all, action: :read, context: user)
assets.order(:name).limit(20)
```

With the ownership rule, this returns the user's assets. With the tenant default scope too, it returns their assets in `Current.organisation`.

Writ returns decisions; your application handles denial. For example:

```ruby
# app/errors/access_denied.rb
class AccessDenied < StandardError; end
```

```ruby
raise AccessDenied unless result.allowed?
```

Map that application exception to your desired response. A model class check tests whether a grant is available; use a record check to authorize a particular asset, or `filter` to obtain an allowed collection.

## Field permissions

Record permissions determine **which assets** a user can access. Field permissions determine **which attributes** they can read or change.

Expand the Member definition with action-specific fields:

```ruby
# Inside the existing Writ.configure block; replaces the Member permission declaration.
with_options model: Asset, role: :Member do
  permission :read, scopes: [:owned]
  permission :create, scopes: [:owned]
  permission :update, scopes: [:owned]
  accessible_fields [:name, :description], action: :read
  accessible_fields [:name, :description], action: :create
  accessible_fields [:name], action: :update
end
```

Members can read `name` and `description`, provide both when creating, and change only `name` afterward.

After authorizing a record, apply the readable fields when serializing it:

```ruby
fields = Writ::Access.readable_fields(context: user, record: asset)
output = fields == :all ? asset.as_json : asset.as_json(only: fields)
```

Field queries return `:all` or an array of string names. Fields are unrestricted when no declaration exists for an action. To require explicit field declarations, set:

```ruby
# config/initializers/writ.rb
Writ.configure do |config|
  config.field_default = []
end
```

Writ returns the allowed field list; your application must apply it to output and submitted attributes. Fields combine across effective roles. See the [reference](docs/reference.md) for batch lookups and field resolvers.

## Creating and updating records

A SQL scope checks records already in the database. Before saving a new or edited asset, Writ also needs a way to check its proposed attributes. A **matcher** is the Ruby equivalent of a scope for that purpose.

Extend the existing ownership scope with `matches:`:

```ruby
# Replaces the :owned scope inside Writ.configure.
scope :owned, model: Asset,
      matches: ->(user, record) { record.owner_id == user.id } do |user|
  Asset.where(owner_id: user.id)
end
```

In a multi-tenant application, extend the default scope too:

```ruby
# Replaces the Asset default_scope inside Writ.configure.
default_scope model: Asset, matches: ->(_user, record) {
  record.organisation_id == Current.organisation.id
} do
  Asset.where(organisation_id: Current.organisation.id)
end
```

`Writ::Access.validation` runs these matchers on the unsaved attributes. It does not save the record. Missing matchers raise by default, so a SQL restriction cannot silently disappear during a write.

### Create

Build ownership and tenancy from your application's authenticated state:

```ruby
asset = Asset.new(owner_id: user.id)
```

For tenant-owned assets, also set the selected organisation:

```ruby
asset = Asset.new(owner_id: user.id, organisation_id: Current.organisation.id)
```

Then apply and validate the submitted fields before saving:

```ruby
# attributes contains the submitted name/description values.
input = attributes.stringify_keys
raise AccessDenied unless (input.keys - %w[name description]).empty?
asset.assign_attributes(input)

fields = Writ::Access.writable_fields(context: user, record: asset, action: :create)
raise AccessDenied unless fields == :all || (input.keys - fields).empty?

result = Writ::Access.validation(subject: asset, action: :create, context: user)
raise AccessDenied unless result.allowed?
asset.save!
```

> `attributes`, `user`, and `AccessDenied` belong to the application. In a controller, obtain attributes with `params.require(:asset).permit(:name, :description).to_h`. Keep ownership and tenant IDs out of user-editable input.

### Update

First authorize the saved record and submitted fields, then check the proposed record. This sequence works for both tenancy modes:

```ruby
asset.with_lock do
  result = Writ::Access.authorization(subject: asset, action: :update, context: user)
  raise AccessDenied unless result.allowed?

  input = attributes.stringify_keys
  fields = Writ::Access.writable_fields(context: user, record: asset, action: :update)
  raise AccessDenied unless fields == :all || (input.keys - fields).empty?

  asset.assign_attributes(input)
  result = Writ::Access.validation(subject: asset, action: :update, context: user)
  raise AccessDenied unless result.allowed?
  asset.save!
end
```

`with_lock` locks and reloads the saved record before assignment. With the example field rules, an update containing `description` is denied. See [Advanced write flows](docs/advanced-writes.md) for nested writes, callbacks, and related-record locking.

## Pundit integration

`rails_writ-pundit` is the recommended integration for applications using Pundit. It connects Writ's permissions to `authorize` and `policy_scope`, using the same database schema and tenancy configuration.

Add the adapter alongside the core gem:

```ruby
# Gemfile
gem "rails_writ-pundit"
```

With the core installation above complete, generate the policy base:

```sh
bundle install
bin/rails generate writ:pundit:application_policy
```

```ruby
# app/policies/application_policy.rb
class ApplicationPolicy < Writ::Pundit::Policy
end
```

To use the core rules already defined in `config/writ/permissions.rb`, add an otherwise empty policy:

```ruby
# app/policies/asset_policy.rb
class AssetPolicy < ApplicationPolicy
end
```

Enable the normal Pundit helpers:

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Pundit::Authorization
end
```

```ruby
# In a controller action:
assets = policy_scope(Asset).order(:name).limit(20)
asset = Asset.find(params[:id])
authorize asset, :show?
```

Pundit passes `current_user` by default. That works with the rules above in both tenancy modes; the tenant example still uses your application's `Current.organisation`.

| Pundit predicate | Writ action |
|---|---|
| `index?`, `show?`, `read?` | `:read` |
| `new?`, `create?` | `:create` |
| `edit?`, `update?` | `:update` |
| `destroy?`, `delete?` | `:delete` |

`policy_scope` filters with `:read`. Predicates check authorization; for writes, also apply field permissions and call `Writ::Access.validation` as above. Pundit raises `Pundit::NotAuthorizedError` on denial; your application chooses the response.

### Defining rules in policies

You can move model rules from `config/writ` into policies if you prefer. The policy infers the model from its class name:

```ruby
# app/policies/asset_policy.rb
class AssetPolicy < ApplicationPolicy
  allow_missing_default_scope

  scope :owned, matches: ->(user, record) { record.owner_id == user.id } do |user|
    Asset.where(owner_id: user.id)
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

Move these declarations out of the core definition file when using this policy. In tenant mode, replace `allow_missing_default_scope` with the same tenant `default_scope` and matcher shown earlier, omitting `model: Asset` inside the policy. Keep the tenant permission-source settings in the initializer.

For a fresh installation using Pundit from the start, `writ:pundit:install` runs the core installer and creates ApplicationPolicy together. It accepts the same tenancy options. See the [adapter guide](https://github.com/NicolasJJensen/rails_writ/tree/main/gems/rails_writ-pundit) for custom predicates, shared conditions, and policy generators.

## More complex rules

### Scope arguments

Arguments let one scope implementation serve permissions with different values. For example, an Inspector role might read only assets at specified locations:

```ruby
# Add inside Writ.configure, alongside the existing scope definitions.
scope :at_locations, model: Asset,
      arguments: { ids: { type: :array, required: true } },
      matches: ->(_user, record, arguments) { arguments[:ids].include?(record.location_id) } do |_user, arguments|
  Asset.where(location_id: arguments[:ids])
end

permission :read, model: Asset, role: :Inspector,
                 scopes: [{ at_locations: { ids: [10, 20] } }]
```

> `Asset.location_id` and the location IDs are application data. The scope definition is Ruby code; its attached argument values are stored with each permission.

A scope receives the current user first and its configured arguments second. Attach `scopes: [:owned, { at_locations: { ids: [10, 20] } }]` to require both ownership and location. A tenant default scope still applies to every permission; configure location IDs appropriate to each tenant.

### Conditions

A condition answers whether a permission is available for this request, rather than filtering records. For example, allow publishing only during business hours:

```ruby
# Add inside Writ.configure.
condition :business_hours do
  (9...17).cover?(Time.current.hour)
end

permission :publish, model: Asset, role: :Member,
                    scopes: [:owned], conditions: [:business_hours]
```

Every condition on a permission must pass. Condition blocks can receive the same context as scopes, and can declare an argument schema too. Check custom actions with `Writ::Access.authorization(..., action: :publish)`; the adapter guide shows how to expose them as Pundit predicates.

### Passing a custom context

The object passed as `context:` is entirely your application's choice. A User is enough for the examples above. If your application prefers to pass a user and selected tenant together, it can use a struct, an existing request object, or another suitable object:

```ruby
RequestContext = Struct.new(:user, :organisation, keyword_init: true)
context = RequestContext.new(user: user, organisation: organisation)
```

Configure where Writ finds the assigned roles and permissions:

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

Scope and matcher blocks receive this same object. Adapt them to read `context.user.id` and `context.organisation.id` in place of `user.id` and `Current.organisation.id`. This is an alternative to the earlier tenant-selection example.

With Pundit, return your chosen object from `pundit_user`. With the core API, pass it through `context:`. Neither gem requires a particular wrapper class or additional request attributes.

## Configuration

The generated initializer holds your settings. Besides the tenancy and source settings already shown, these are the usual options:

| Setting | Default | Purpose |
|---|---|---|
| `default_role_name` | `"Default Role"` | Selects a new organisation's default role by name. |
| `field_default` | `:all` | Field access when no action-specific fields are declared; use `[]` for explicit opt-in. |
| `on_missing_condition` | `:raise` | A stored permission references an undefined condition. |
| `on_condition_error` | `:raise` | A condition raises during evaluation. |
| `on_invalid_scope_arguments` | `:raise` | Stored scope arguments do not match their schema. |
| `on_invalid_condition_arguments` | `:raise` | Stored condition arguments do not match their schema. |
| `on_missing_default_scope` | `:raise` | A scoped model has no default scope or explicit exemption. |
| `on_missing_matcher` | `:raise` | A scope has no matcher for proposed-state validation. |

For example, to exclude a permission whose condition raises while leaving other valid permissions available:

```ruby
Writ.configure do |config|
  config.on_condition_error = :deny
end
```

Missing conditions and invalid arguments also support `:deny`. Missing default scopes and matchers instead support `:warning` or `:skip`, which continue without that constraint. Keep the default errors unless your application deliberately accepts its absence.

### Additional write validators

Use a validator when a proposed record needs checks beyond its scope matchers:

```ruby
# config/writ/asset_validators.rb
Writ.configure do
  creation_validator model: Asset do |context:, record:|
    record.owner_id == context.id && record.name.present?
  end

  update_validator model: Asset do |context:, record:|
    record.name.present?
  end
end
```

These examples use a User as context. Validators run only through `Writ::Access.validation` for their matching create/update action. Every applicable validator must pass. See [API and advanced configuration](docs/reference.md) for additional options.

## Existing applications

### Initializing existing organisations

New organisations receive defaults through their callback. To initialize an organisation created before Writ was installed, with no roles yet:

```sh
ID=42 MODEL=Organisation bin/rails writ:generate
```

Global generation likewise requires an empty role table. Generation creates initial authorization data; it does not reset an existing permission system.

### Updating existing permissions

Changing Ruby permission declarations does not overwrite saved grants or tenant customizations. After adding a new model/action, apply its defaults explicitly.

For shared roles:

```ruby
Writ::Generator.add_permissions(permissions: [{ model: Asset, action: :publish }])
```

For organisation-owned roles:

```ruby
Organisation.find_each do |organisation|
  Writ::Generator.add_permissions(
    organisation, permissions: [{ model: Asset, action: :publish }]
  )
end
```

Run these through an application data migration or setup service. Changes to an existing action's scopes, conditions, arguments, or fields need a deliberate migration of the stored data. See [Permission management](docs/permission-management.md) for migration and cleanup behavior.

## Advanced guides

- [API and advanced configuration](docs/reference.md): query contracts, custom models and keys, field resolvers, STI, and reloading.
- [Permission management](docs/permission-management.md): stored grants, tenant-specific arguments, migrations, and cleanup.
- [Advanced write flows](docs/advanced-writes.md): nested records, callbacks, concurrency, and transitions.
- [Performance and instrumentation](docs/performance.md): batch costs, notifications, and profiling.

## Development and contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for PostgreSQL setup, testing both gems, and packaging. Issues and pull requests are welcome on [GitHub](https://github.com/NicolasJJensen/rails_writ). User-visible changes are recorded in the [changelog](CHANGELOG.md).

## License

Both gems use the [MIT License](LICENSE.txt).
