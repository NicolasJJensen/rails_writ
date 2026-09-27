# Upgrading

[Back to README](../README.md)

## 0.1 to 0.2: separate Pundit integration

Version 0.2 extracts policy helpers, policy generators, and policy loading into `rails_writ-pundit`. It does not require authorization-table changes solely for the split.

### Applications using policies

Replace the Gemfile entry with:

```ruby
gem "rails_writ-pundit", "~> 0.2.0"
```

The adapter brings in core and Pundit. Then update the base class:

```ruby
class ApplicationPolicy < Writ::Pundit::Policy
  # Retain your own overrides and shared conditions here.
end
```

If you maintain a fully custom base class, replace `include Writ::PolicyHelpers` with `include Writ::Pundit::PolicyHelpers` instead. Existing model policy declarations keep their syntax.

| Previous entry point | Replacement |
|---|---|
| `require "writ/policy_helpers"` | `require "rails_writ/pundit"` |
| `writ:application_policy` | `writ:pundit:application_policy` |
| `writ:policy` | `writ:pundit:policy` |
| Policy-generating `writ:install` | `writ:pundit:install` for new installations |
| `writ:conditions` | Define shared conditions on the base policy or retain your existing concern. |

Do not rerun the full installer over customized models or existing migrations. Existing Conditions concerns remain application-owned; new installs no longer create an empty one.

The old `config.writ.policies_dir` setting is removed. The adapter uses conventional `app/policies`; relocate custom policy directories or register an explicit loader through `config.writ.definition_loaders` before Writ prepares definitions.

### Applications using only core

Keep `gem "rails_writ"`, update to 0.2, and place model-dependent definitions in `config/writ/*.rb` using `Writ.configure`. Core no longer loads `app/policies` or exposes `Writ::PolicyHelpers`.

Settings remain in `config/initializers/writ.rb`. The README provides complete core definitions for both tenancy modes. Retain existing database grants and role assignments; do not regenerate defaults over them.

### Verify the migration

For both global and tenant-owned roles, check permitted and denied reads, filtering, creates, updates, and field enforcement. For tenant applications also verify that one tenant's roles and records cannot be used in another tenant's context. Check development reload and production eager loading.

## Older generated schemas: determine whether changes apply

The following changes predate the split. Their original generator versions are not recorded here, so inspect the actual schema rather than assuming a version needs migration. Use your real table names when authorization models are namespaced.

### Provenance columns

In a Rails console:

```ruby
connection = ActiveRecord::Base.connection
connection.column_exists?(:permissions, :generated_signature)
connection.column_exists?(:roles, :generated_fields)
```

If either returns false, add only the missing column in a Rails migration:

```ruby
add_column :permissions, :generated_signature, :string
add_column :roles, :generated_fields, :jsonb, default: {}, null: false
```

Leave existing grant provenance unset. Do not label all existing/custom grants as generated. Cleanup deliberately preserves untracked grants.

### Membership table naming

Rails removes shared prefixes when inferring HABTM table names. For actor table `review_auth_accounts` and role table `review_auth_roles`, the expected membership table is `review_auth_accounts_roles`.

Check which table exists:

```ruby
connection = ActiveRecord::Base.connection
connection.table_exists?(:review_auth_accounts_review_auth_roles)
connection.table_exists?(:review_auth_accounts_roles)
```

If only the old concatenated name exists, an application migration can rename it:

```ruby
rename_table :review_auth_accounts_review_auth_roles, :review_auth_accounts_roles
```

Remove the old generated `join_table:` override afterward, and verify the model reflection resolves the renamed table. If both tables exist, inspect their data and associations before choosing a migration.

The Role model also needs the inverse actor association, for example `has_and_belongs_to_many :users`. This applies to both tenancy modes; tenant ownership does not replace actor membership.
