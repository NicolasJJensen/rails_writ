# Writ

Writ adds database-backed permissions and roles to Rails. Control which records and fields a user can access, with shared roles for a single-tenant application or separate roles for each organisation.

A **permission** allows an action on a model, such as reading an Asset. A **role** is a named group of permissions, such as Member. Many users can share a role, and each user can have several roles.

Ruby declarations define the **defaults** used to create roles, permissions, and field settings in the database. Access checks use those stored values, which your application can customize. Scopes and conditions supply the Ruby implementations of restrictions; stored permissions choose which restrictions and arguments to use. Defaults are generated once globally or once per tenant, not separately for every user.

`rails_writ` provides the core system. For Rails controllers, the recommended integration is the optional `rails_writ-pundit` adapter, which connects it to Pundit's normal policies and parameter handling.

## Contents

- [Basic setup](#basic-setup)
  - [Install](#install)
  - [Configure tenancy](#configure-tenancy)
  - [Define initial permissions](#define-initial-permissions)
  - [Generate and assign roles](#generate-and-assign-roles)
- [Defining permissions](#defining-permissions)
  - [Record scopes](#record-scopes)
  - [Using the current user](#using-the-current-user)
  - [Combining scopes and permissions](#combining-scopes-and-permissions)
  - [Default scopes and tenants](#default-scopes-and-tenants)
  - [Scope arguments](#scope-arguments)
  - [Conditions](#conditions)
  - [Field permissions](#field-permissions)
  - [Default roles](#default-roles)
- [Using Pundit](#using-pundit)
  - [Install the adapter](#install-the-adapter)
  - [Policies and access checks](#policies-and-access-checks)
  - [Creating and updating records](#creating-and-updating-records)
  - [Rendering errors](#rendering-errors)
  - [Parameters and custom nesting](#parameters-and-custom-nesting)
- [Using the core API](#using-the-core-api)
- [Configuration and loading](#configuration-and-loading)
  - [Custom context and sources](#custom-context-and-sources)
- [Updating existing permissions](#updating-existing-permissions)
- [Further reading](#further-reading)
- [Development and license](#development-and-license)

## Basic setup

### Install

Requires Ruby 3.1+, Rails / ActiveRecord 7.x or 8.x, and PostgreSQL.

```ruby
# Gemfile
gem "rails_writ"
```

```sh
bundle install
bin/rails generate writ:install
bin/rails db:migrate
```

For organisation-owned roles, use the tenant installer instead:

```sh
bin/rails generate writ:install --multi-tenant --scoping-model=Organisation
bin/rails db:migrate
```

The installer adds role membership to `User`, creates the authorization models and migrations, and writes `config/initializers/writ.rb` and `config/writ/permissions.rb`.

| Setup | Generated differences |
|---|---|
| Single tenant | Shared roles, with unique role names across the application. |
| Multi-tenant | Roles belong to an organisation; names are unique within it. Organisations gain a default-role association and a callback that generates their initial roles. |

> `User`, `Organisation`, and `Asset` in these examples are application models. The installer creates Writ's authorization models. Other actor names, namespaces, and primary keys are supported through [generator options](docs/reference.md#custom-models-namespaces-and-keys).

### Configure tenancy

Single-tenant applications need no tenant settings. The tenant installer configures the model and a callback for finding the selected tenant:

```ruby
# config/initializers/writ.rb — tenant applications
Writ.configure do |config|
  config.scoping_model = "Organisation"
  config.tenant_source = ->(_user) { Current.organisation }
end
```

Setting `scoping_model` enables tenant mode. `tenant_source` tells Writ **which organisation is active for this operation**. Writ then selects only the user's assigned roles and permissions belonging to that organisation. An absent or invalid tenant does not grant access.

> `Current.organisation` is an example of application-owned tenant selection. Use your application's authenticated selection here; Writ does not choose a tenant or establish membership for you.

Role selection and record filtering are separate: add the [default scope](#default-scopes-and-tenants) for each tenant-owned model you protect.

### Define initial permissions

```ruby
# config/writ/permissions.rb
Writ.configure do
  permission :read, model: Asset, role: :Member
end
```

This gives the Member role permission to read assets. Without a record scope, the permission includes all assets within any default scope. Users without a matching stored permission are denied.

Writ loads `config/writ/**/*.rb` during Rails preparation and reloads it in development. These files are explicitly loaded by Writ; they are not Rails-autoloaded model classes.

### Generate and assign roles

For shared roles, generate the defaults after saving your definitions:

```sh
bin/rails writ:generate
```

Assign the resulting role in your application's enrollment flow:

```ruby
user.roles << Role.find_by!(name: "Member")
```

In tenant mode, new organisations receive their default roles through the generated callback. Assign from the appropriate organisation:

```ruby
user.roles << organisation.roles.find_by!(name: "Member")
```

You can now check access:

```ruby
Writ::Access.authorization(subject: asset, action: :read, context: user).allowed?
```

The `context:` is the object performing the operation—normally the user. No context wrapper is required. The [Pundit integration](#using-pundit) supplies `current_user` automatically.

## Defining permissions

The standard actions are `:read`, `:create`, `:update`, and `:delete`. Custom actions such as `:publish` work too. The following examples progressively refine the initial permission definition.

> Changes to default declarations affect future generation. To apply them to stored roles, see [Updating existing permissions](#updating-existing-permissions). Changing a scope's Ruby implementation affects every stored permission that uses that scope.

### Record scopes

A **scope** restricts a permission to particular records. Replace the unrestricted read definition with:

```ruby
# config/writ/permissions.rb
Writ.configure do
  scope :published, model: Asset do
    query { Asset.where(published: true) }
  end

  permission :read, model: Asset, role: :Member, scopes: [:published]
end
```

Members can now read only assets whose `published` attribute is true. `query` returns an ordinary ActiveRecord relation; Writ uses it for list filtering and saved-record checks.

For permissions that create or update records, the scope also needs to check **proposed attributes before they are saved**. Add a `validate` block:

```ruby
# Inside Writ.configure; replaces the published scope above.
scope :published, model: Asset do
  query { Asset.where(published: true) }

  validate do |asset, errors|
    errors.add(:published, :not_permitted, message: "must remain published") unless asset.published?
  end
end
```

`validate` receives the proposed record and an isolated Rails error collection. Adding an error rejects that scope; the block's return value is ignored. Keep the query and validation equivalent. Ordinary model rules, such as requiring a name, still belong in ActiveRecord validations.

### Using the current user

A query or validator can request `context:` when it needs the user:

```ruby
# Inside Writ.configure
scope :owned, model: Asset do
  query { |context:| Asset.where(owner_id: context.id) }

  validate do |asset, errors, context:|
    unless asset.owner_id == context.id
      errors.add(:owner_id, :not_permitted, message: "must belong to you")
    end
  end
end
```

Attach `scopes: [:owned]` to a permission to restrict it to the user's assets. Here, `owner_id` is your application's ownership column; `context` is the user passed to the access check.

### Combining scopes and permissions

With the `published` and `owned` scopes defined above:

```ruby
# Inside Writ.configure; replaces the Member read declaration.
permission :read, model: Asset, role: :Member, scopes: [:published, :owned]
permission :read, model: Asset, role: :Reviewer, scopes: [:published]
```

A Member must satisfy **both** scopes: the asset must be published and owned by that user. A user who also holds Reviewer can read any published asset, because **either permission** can grant access. A default scope, when defined, constrains both alternatives.

Proposed validation follows the same rule. Errors from a rejected alternative are discarded if another permission allows the proposal. When all alternatives fail, Writ exposes their shared errors, or a general error when their reasons differ.

### Default scopes and tenants

A **default scope** is a mandatory record boundary applied to every permission for a model, including permissions without named scopes. Unlike role defaults, this boundary is enforced directly from code. It is separate from ActiveRecord's `default_scope`.

For tenant-owned assets, add:

```ruby
# Inside Writ.configure — tenant applications
default_scope model: Asset do
  query do |context:|
    Asset.where(organisation_id: Writ::Configuration.tenant_for(context).id)
  end

  validate do |asset, errors, context:|
    unless asset.organisation_id == Writ::Configuration.tenant_for(context).id
      errors.add(:organisation_id, :not_permitted, message: "must remain in the selected organisation")
    end
  end
end
```

Combined with `owned`, Members can access only their own assets in the selected organisation. Holding a second organisation's role does not widen that boundary. The same default scope prevents a proposed edit from moving an asset to another organisation.

In tenant mode, models using named scopes require a default scope. For a deliberately shared model, such as a country catalog, declare the exemption explicitly:

```ruby
# Inside Writ.configure
allow_missing_default_scope model: Country
```

Single-tenant applications do not need this exemption. They can still define default scopes for application-wide boundaries.

### Scope arguments

Arguments let one scope implementation support different stored restrictions. For example, permissions can select different locations:

```ruby
# Inside Writ.configure
scope :at_locations, model: Asset,
      arguments: { ids: { type: :array, required: true } } do
  query do |arguments:|
    Asset.where(location_id: arguments.fetch(:ids))
  end

  validate do |asset, errors, arguments:|
    unless arguments.fetch(:ids).include?(asset.location_id)
      errors.add(:location_id, :not_permitted, message: "is not available to you")
    end
  end
end

permission :update, model: Asset, role: :Inspector,
                   scopes: [{ at_locations: { ids: [10, 20] } }]
```

Inspectors can update assets at locations 10 or 20 and cannot move them to another location. Both callbacks receive the same normalized arguments from the stored permission attachment. They can also request `context:`. In tenant mode, the default scope continues to restrict these locations to the selected tenant.

### Conditions

A **condition** determines whether a permission is available at all, rather than selecting records:

```ruby
# Inside Writ.configure
condition :business_hours do |_user|
  (9...17).cover?(Time.current.hour)
end

permission :update, model: Asset, role: :Member,
                   scopes: [:owned], conditions: [:business_hours]
```

This update permission works only during business hours and only for owned assets. Every attached condition must pass. Conditions can also have argument schemas; see [parameterized rules](docs/reference.md#parameterized-rules).

### Field permissions

Record permissions select **which assets** are accessible. Field permissions select **which attributes** a role can read or change for an action. Field settings belong to the role, not to individual permissions.

```ruby
# Inside Writ.configure; replaces the Member declarations.
with_options model: Asset, role: :Member do
  permission :read, scopes: [:owned]
  permission :create, scopes: [:owned]
  permission :update, scopes: [:owned]

  accessible_fields [:name, :description], action: :read
  accessible_fields [:name, :description], action: :create
  accessible_fields [:name], action: :update
end
```

Members can read `name` and `description`, supply both on creation, and change only `name` afterward. These settings are stored on the role; multiple permissions for that role/model/action share them. Fields from contributing roles combine.

Use `:all` for unrestricted fields or `[]` for none. Omitting `action:` applies the declaration to the four standard actions; declare custom actions explicitly. Undeclared fields default to `:all`; to require explicit lists throughout the application:

```ruby
# config/initializers/writ.rb
Writ.configure do |config|
  config.field_default = []
end
```

The Pundit adapter supplies writable fields to Strong Parameters. For serializers or core integrations:

```ruby
fields = Writ::Access.readable_fields(context: user, record: asset)
data = fields == :all ? asset.attributes : asset.attributes.slice(*fields)
```

Field decisions do not serialize records themselves. Nested records need their own authorization.

### Default roles

An organisation's **default role** records the role your application intends to assign to new members. Configure its name before generating tenant roles:

```ruby
# config/initializers/writ.rb
Writ.configure do |config|
  config.default_role_name = "Member"
end
```

Generation stores that role as `organisation.default_user_role`. Your enrollment flow controls the assignment:

```ruby
user.roles << organisation.default_user_role
```

The default name is `"Default Role"`; if no generated role matches it, no default is selected. Shared-role applications can look up their chosen role directly.

## Using Pundit

### Install the adapter

```ruby
# Gemfile
gem "rails_writ-pundit"
```

```sh
bundle install
bin/rails generate writ:pundit:application_policy
```

This adds `ApplicationPolicy < Writ::Pundit::Policy` to the core setup above. For a fresh application, `writ:pundit:install` combines both installers and accepts the same tenant options.

### Policies and access checks

Keep your definitions in `config/writ/permissions.rb` and add:

```ruby
# app/policies/asset_policy.rb
class AssetPolicy < ApplicationPolicy
end
```

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Pundit::Authorization
end
```

Pundit supplies `current_user` as Writ's context. Use its usual helpers:

```ruby
policy_scope(Asset).order(:name).limit(20)
authorize @asset, :show?
```

`policy_scope` filters on `:read`. `show?`/`index?` map to `:read`, `create?`/`new?` to `:create`, `update?`/`edit?` to `:update`, and `destroy?` to `:delete`.

You can instead put declarations in policies, where the model is inferred. For example, move the ownership and field definitions into:

```ruby
# app/policies/asset_policy.rb
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

In tenant mode, also move the default-scope declaration into the policy, omitting `model: Asset`. Define each scope in one place. See the [adapter guide](https://github.com/NicolasJJensen/rails_writ/tree/main/gems/rails_writ-pundit#readme) for custom actions and shared conditions.

### Creating and updating records

Use `authorize` to check whether the operation is available on the existing record. Then `authorize_proposed!` checks the submitted fields and proposed record before `save!` runs normal model validations:

```ruby
class AssetsController < ApplicationController
  before_action :build_asset, only: :create
  before_action :set_asset, only: :update

  def create
    authorize @asset, :create?
    authorize_proposed!(@asset, attributes: permitted_attributes(@asset))
    @asset.save!
    redirect_to @asset
  end

  def update
    authorize @asset, :update?
    authorize_proposed!(@asset, attributes: permitted_attributes(@asset))
    @asset.save!
    redirect_to @asset
  end

  private

  def build_asset
    @asset = Asset.new
  end

  def set_asset
    @asset = Asset.find(params[:id])
  end
end
```

> Build records through your application's usual associations or service when it supplies ownership or tenancy. The example shows where that application logic belongs; Writ does not populate those attributes.

The helper is automatically available with `Pundit::Authorization`. It infers `:create` for a new record and `:update` for a persisted one; pass `action:` for another operation. It assigns `attributes:` when supplied, checks their keys, and never saves.

If attributes were already assigned, omit that argument:

```ruby
@asset.assign_attributes(permitted_attributes(@asset))
authorize_proposed!(@asset)
@asset.save!
```

This checks fields reported by Rails dirty tracking. Passing `attributes:` explicitly checks every supplied key, including unchanged values; passing an empty hash checks no submitted fields. Both forms validate the whole proposed record against its scopes.

The adapter's `permitted_attributes_for_create` and `permitted_attributes_for_update` provide candidate fields before assignment. Create candidates do not run proposed-state validators against an empty record. `authorize_proposed!` performs the final proposed-state check after assignment.

### Rendering errors

A rejected proposal raises `Writ::Pundit::ProposedAuthorizationError`, carrying `record` and `result`. Writ copies the final field/base errors onto the record, so forms use ordinary `record.errors`. Repeated checks replace only earlier Writ-added errors and preserve unrelated model errors.

Handle this alongside model validation failures at the bottom of your controller:

```ruby
# Inside AssetsController
rescue_from Pundit::NotAuthorizedError, with: :render_forbidden
rescue_from ActiveRecord::RecordInvalid,
            Writ::Pundit::ProposedAuthorizationError,
            with: :render_invalid_record

private

def render_forbidden
  head :forbidden
end

def render_invalid_record(error)
  @asset = error.record
  respond_to do |format|
    format.html do
      render(@asset.persisted? ? :edit : :new, status: :unprocessable_entity)
    end
    format.json do
      render json: { errors: @asset.errors.to_hash, details: @asset.errors.details },
             status: :unprocessable_entity
    end
  end
end
```

A missing permission is a **403**; a disallowed proposal or ordinary model validation failure is a **422**. The specific rescue is declared after the general Pundit rescue because Rails searches handlers in reverse order.

Turbo Drive can render the same HTML form with status 422. A Turbo Frame response must contain the matching frame. If your form requests Turbo Stream responses, add a `format.turbo_stream` branch rendering your application's stream template with status 422. Writ supplies decisions and record errors; the host chooses templates and response formats.

### Parameters and custom nesting

`permitted_attributes(@asset)` is Pundit's helper. For `Asset`, it normally reads `params.require(:asset)` and calls `permit` with the policy's field list. The adapter supplies that list; it does not read controller parameters itself.

For a request such as `{ data: { asset: { name: "New name" } } }`, override Pundit's parameter hook:

```ruby
# Inside your controller
def pundit_params_for(record)
  params.require(:data).require(Pundit::PolicyFinder.new(record).param_key)
end
```

For nested arrays or attributes, define the Strong Parameters structure in the policy; see [nested parameters](https://github.com/NicolasJJensen/rails_writ/tree/main/gems/rails_writ-pundit#nested-parameters). `:all` expands to model attribute names, never `permit!`.

## Using the core API

The core gem works without Pundit. These methods share the same definitions and tenant selection:

```ruby
result = Writ::Access.authorization(subject: asset, action: :read, context: user)
result.allowed?
result.reason

assets = Writ::Access.filter(records: Asset.all, action: :read, context: user)
assets.order(:name).limit(20)
```

For writes, check saved access before assignment, use your application's parameter handling, then validate the proposal:

```ruby
saved = Writ::Access.authorization(subject: asset, action: :update, context: user)
raise AccessDenied unless saved.allowed?

asset.assign_attributes(attributes)
result = Writ::Access.validation(
  subject: asset, action: :update, context: user,
  submitted_fields: asset.changed_attribute_names_to_save
)
result.apply_errors_to(asset)
raise ActiveRecord::RecordInvalid, asset unless result.allowed?
asset.save!
```

> `AccessDenied` is an application exception. Core checks return results and do not choose HTTP responses. Use `:create` with a new record for creation; its initial authorization checks grant availability, then `validation` checks proposed values.

`input_fields` returns candidate fields before assignment. `readable_fields` and `writable_fields` return field decisions for the given record. Passing `submitted_fields:` to core validation adds field checks; omitting it checks the proposal's scopes and validators without checking a submitted field list.

## Configuration and loading

Keep application settings in `config/initializers/writ.rb` and model-dependent declarations in `config/writ/*.rb` or Pundit policies. Writ rebuilds its rule registry on Rails reloads; initializer configuration is replayed before definition files. A failed rebuild preserves the last complete registry.

| Setting | Purpose |
|---|---|
| `scoping_model` | Tenant model name/class; unset means shared roles. |
| `tenant_source` | Resolves the active tenant from the operation's context. |
| `default_role_name` | Selects a new tenant's default-role association. |
| `field_default` | Fields used when no field list is declared; defaults to `:all`. |
| `role_source`, `permission_source` | Override the normal role and permission lookup. |

### Custom context and sources

A context can be any object your application chooses. Pundit uses `current_user` unless you override `pundit_user`. If using a wrapper, tell Writ how to obtain its roles and permissions:

```ruby
Writ.configure do |config|
  config.role_source = ->(context) { context.user.roles }
  config.permission_source = ->(context) { context.user.permissions }
end
```

These callbacks replace the corresponding default lookup. In tenant mode, custom sources must filter to the selected tenant themselves; ordinary User contexts use the built-in filtering and do not need these overrides. Scopes and conditions receive the same context object.

See the [configuration reference](docs/reference.md) for custom models, resolvers, failure modes, and standalone loading.

## Updating existing permissions

Definition changes do not overwrite customized roles. To add defaults for a new model/action to existing shared roles:

```ruby
Writ::Generator.add_permissions(permissions: [{ model: Asset, action: :publish }])
```

For tenant roles:

```ruby
Organisation.find_each do |organisation|
  Writ::Generator.add_permissions(organisation, permissions: [{ model: Asset, action: :publish }])
end
```

To initialize an existing organisation that has no roles:

```sh
ID=42 bin/rails writ:generate
```

The task uses `scoping_model`; `MODEL=Organisation` can select it explicitly. Existing roles, scope changes, argument migrations, and removal of obsolete defaults need deliberate updates. See [Permission management](docs/permission-management.md).

## Further reading

- [Adapter guide](https://github.com/NicolasJJensen/rails_writ/tree/main/gems/rails_writ-pundit#readme): policy customization, nested parameters, and shared conditions.
- [API and configuration reference](docs/reference.md): decision contracts, generators, failure modes, and loading.
- [Advanced writes](docs/advanced-writes.md): locking, associations, and error isolation.
- [Permission management](docs/permission-management.md): updating and retiring stored defaults.
- [Performance](docs/performance.md): batch field access, instrumentation, and profiling.

## Development and license

See [CONTRIBUTING](CONTRIBUTING.md) for testing both packages. Writ is available under the [MIT License](LICENSE.txt).
