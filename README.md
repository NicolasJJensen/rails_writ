# Writ

Writ adds database-backed roles and permissions to Rails applications. Define permission defaults in Ruby, assign roles to users, and check access to records and individual fields.

Use it when permissions need to be stored and customized per installation or tenant:

- **Roles and permissions** stored in your application's database.
- **Record scopes** that filter ActiveRecord queries to permitted records.
- **Conditions** that depend on the current user or request context.
- **Field permissions** for controlling readable and writable attributes.
- **Proposed-state validation** for checking new records and pending changes.

[Quick start](#quick-start) · [Usage](#usage) · [Documentation](#documentation)

## Requirements

- Ruby 3.1 or later, with a compatible Rails version.
- Rails / ActiveRecord 7.x or 8.x. See the [compatibility matrix](CONTRIBUTING.md#compatibility-checks) for tested version targets.
- PostgreSQL for the generated migrations, which use JSONB.
- Models with single-column primary keys; UUID and custom key names are supported.

Writ integrates with ActiveRecord. Your application enforces its decisions in controllers, services, or jobs. Pundit integration is optional.

## Installation

Add Writ to your Gemfile:

```ruby
gem "rails_writ"
```

Then install the bundle:

```sh
bundle install
```

## Quick start

This example uses global roles in an application with existing `User` and `Asset` models. `Asset` has an `owner_id` referencing a user, plus `name` and `description` attributes. Start with an empty Writ role table.

### 1. Generate the setup

```sh
bin/rails generate writ:install
bin/rails db:migrate
```

The installer creates authorization models, migrations, an initializer, and a base policy. It also adds role membership to `User`. The generated initializer sets `multi_tenant = false` for this setup.

For tenant-owned roles or different model names, see [Installation and integration](docs/installation.md).

### 2. Define a policy

Create `app/policies/asset_policy.rb`:

```ruby
class AssetPolicy < ApplicationPolicy
  scope :owned,
        matches: ->(user, record) { record.owner_id == user.id } do |user|
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

The SQL scope filters saved records. Its `matches:` predicate checks proposed attributes when creating or updating a record.

### 3. Generate permissions and assign a role

After saving the policy, generate the initial database roles and permissions:

```sh
bin/rails writ:generate
bin/rails console
```

In the console, assign the generated role to an existing user:

```ruby
user = User.first!
user.roles << Role.find_by!(name: "Member")
```

Default generation is for an empty role table. After initial setup, use [permission migrations](docs/permission-lifecycle.md#adding-permissions) to introduce new actions. Editing policy defaults does not overwrite existing database grants.

### 4. Check access

Continue in the console:

```ruby
asset = Asset.create!(owner_id: user.id, name: "Demo asset")

Writ::Access.authorization(
  subject: asset, action: :read, context: user
).allowed? # => true

Writ::Access.filter(
  records: Asset.all, action: :read, context: user
) # => an ActiveRecord relation containing only this user's assets
```

The asset above is demo data. For application writes, check proposed attributes before saving as shown below.

## Core concepts

| Concept | Purpose |
|---|---|
| Role | A named set of permissions assigned to a user, such as `Member`. |
| Permission (grant) | Allows an action on a model, optionally restricted by scopes and conditions. |
| Scope | Selects permitted records using an ActiveRecord relation. A matcher checks the equivalent proposed state. |
| Condition | Determines whether a grant applies to the current context. |
| Context | The user or application object supplied to a check. By default, it exposes `permissions` and `roles` relations. |

Scopes within one grant intersect. Separate valid grants combine to allow access. A policy's default scope constrains every grant.

For tenant applications, supply permissions and roles for the current tenant and define the record boundary in a default scope. See [Context and configuration](docs/configuration.md).

## Usage

These examples continue with the `AssetPolicy` and `user` above. `attributes` represents application-supplied input with string keys.

### Authorizing records

```ruby
result = Writ::Access.authorization(
  subject: asset, action: :read, context: user
)

result.allowed?      # true or false
result.reason        # a symbol describing the decision
result.denied_grants # details when access is denied
```

Enforce `allowed?` before returning data or performing an action. Passing a model class checks grant availability; authorize the actual record when deciding access to that record.

### Filtering collections

```ruby
assets = Writ::Access.filter(
  records: Asset.all, action: :read, context: user
).order(:name).limit(20)
```

Filter first, then paginate. `filter` returns a lazy relation. Authorizing a collection instead checks that **every record before pagination** is permitted; it does not remove denied records.

### Validating creates and updates

Check new attributes before saving:

```ruby
asset = Asset.new(owner_id: user.id, name: "New asset")
result = Writ::Access.validation(
  subject: asset, action: :create, context: user
)
asset.save! if result.allowed?
```

For an update, the application flow is:

```text
Authorize the saved record
Check submitted keys against writable fields
Assign the permitted attributes
Validate the proposed record
Save only if validation allows it
```

Saved-record authorization and proposed-state validation are separate checks. Generated policy methods such as `create?` and `update?` do not run proposed-state validation. See [Creating and updating records](docs/record-changes.md) for complete examples, matchers, validators, and transaction/locking guidance.

### Field permissions

```ruby
Writ::Access.readable_fields(context: user, record: asset)
# => ["name", "description"]

fields = Writ::Access.writable_fields(
  context: user, record: asset, action: :update
)
# => ["name"]

permitted_keys = fields == :all || (attributes.keys - fields).empty?
```

Results are `:all` or an array of string names. Your application must enforce them in serializers and input handling, in addition to authorizing the action. Missing field declarations default to `:all`; set `config.field_default = []` for explicit opt-in fields. See [Field permissions](docs/fields.md).

## Documentation

- [Installation and integration](docs/installation.md): tenants, custom models and keys, optional Pundit integration.
- [Configuration](docs/configuration.md): context sources, conditions, failure modes, STI, reloading.
- [Authorization reference](docs/authorization.md): supported subjects, results, SQL and collection behavior.
- [Creating and updating records](docs/record-changes.md): proposed-state checks and safe write flows.
- [Field permissions](docs/fields.md): declarations, defaults, and dynamic resolvers.
- [Permission lifecycle](docs/permission-lifecycle.md): generating defaults, migrating grants, and cleanup.
- [Performance and instrumentation](docs/performance.md): batch fields, notifications, and benchmarks.
- [Upgrading](docs/upgrading.md): schema and association changes for existing installations.

## Development

The test suite uses a Rails application backed by PostgreSQL. See [Contributing](CONTRIBUTING.md) for database setup and supported test configurations.

```sh
bundle exec rspec
```

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/NicolasJJensen/rails_writ). See the [contribution guide](CONTRIBUTING.md) and [changelog](CHANGELOG.md).

## License

Writ is available under the [MIT License](LICENSE.txt).
