# Upgrading

[Back to README](../README.md) · [Documentation index](README.md)

Apply these notes only to installations generated before the relevant schema or association changes. Use your application's actual table and model names.

## Membership table naming

Membership tables follow Rails' HABTM naming convention, including shared-prefix removal.
Both generated Role associations and `as_roleable` use Rails inference. For example,
`review_auth_accounts` and `review_auth_roles` use `review_auth_accounts_roles`.
Existing installations generated with the older concatenated name need a host migration
to rename that table (for example, from `review_auth_accounts_review_auth_roles`) and removal
of the old generated `join_table:` override. The gem does not rename existing tables.

## Generated permission provenance

Existing installations that predate provenance tracking need an additive host migration:

```ruby
add_column :permissions, :generated_signature, :string
add_column :roles, :generated_fields, :jsonb, default: {}, null: false
```

Use your authorization table names. Leave existing provenance unset.
Do not mark custom grants as generated through an indiscriminate backfill.
Existing Role models also need the inverse actor membership association, such as `has_and_belongs_to_many :users`.
Review generated model templates before applying them to customized models.

See [Permission lifecycle](permission-lifecycle.md) for migrating stored grants and rule arguments.
