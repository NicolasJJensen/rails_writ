# Permission management

[README](../README.md) explains initial installation and assignment for both tenancy modes. This guide covers managing stored grants after setup. It applies with or without Pundit.

## Initial generation and tenant callbacks

| Mode | Empty owner | Generation |
|---|---|---|
| Single tenant | Entire role table | `Writ::Generator.generate_default_permissions` |
| Multi-tenant | One organisation's roles | `Writ::Generator.generate_default_permissions(organisation)` |

Generation rejects an owner that already has roles. It does not reset existing permissions.

Generated tenant models use `as_roleable(scoping_model: true)`, which generates defaults after creation. To derive arguments in a setup service, replace that declaration with:

```ruby
# Inside Organisation; replace the existing as_roleable call.
as_roleable(scoping_model: true, auto_generate: false)
```

Then call generation explicitly from that service after constructing the tenant. Do not declare conflicting roleable options twice. Identical declarations are a no-op, including inherited declarations.

Users receive roles only when the application assigns them. Default-role metadata is not automatic user membership.

## Add a new model/action

Add the permission to your core definitions or adapter policy first. Then apply the selected defaults.

Single tenant:

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

| Situation | Outcome |
|---|---|
| Configured role is absent | Creates it. |
| Role has no grant for the selected model/action | Creates all configured alternatives for that pair. |
| Role already has any grant for that pair | Preserves it, including customized scopes. |
| Field values already exist | Preserves them. |
| Selection is empty or unknown | Raises before writing. |
| Repeated migration | Does not add duplicate model/action grants. |

Each owner is migrated in a transaction, with role locks. Keep definitions stable during the migration. Renamed roles remain unchanged; the configured role name can be created separately. Introducing an alternative scope for an existing action requires a deliberate application migration.

`Generator.generate_permissions` accepts complete grant definitions for lower-level migrations. It also preserves existing model/action grants and field values; it is not a synchronization/reset API.

## Tenant-specific condition arguments

Define a parameterized condition and attach it as a template:

```ruby
# config/writ/permissions.rb
Writ.configure do
  condition :tenant_ids, arguments: { ids: { type: :array, required: true } } do |context, arguments|
    arguments[:ids].include?(context.organisation.id)
  end

  permission :read, model: Asset, role: :Member, conditions: [:tenant_ids]
end
```

This example uses the README's multi-tenant context and requires Asset's default tenant scope. Use it instead of declaring the same Member/read grant elsewhere.

Disable automatic generation as shown above and supply concrete values:

```ruby
Writ::Generator.generate_default_permissions(
  organisation, condition_arguments: { tenant_ids: { ids: [organisation.id] } }
)
```

The registry template stays unchanged. Wrong types or unknown keys fail at configuration time when supplied there; missing required values fail when concrete permissions are saved. A failed generation rolls back.

Single-tenant applications do not need this tenant condition. For their own parameterized conditions, pass `condition_arguments:` to global generation without an organisation argument.

## Retire generated defaults

Preview before deleting:

```sh
DRY_RUN=1 bin/rails writ:cleanup
```

Apply the reviewed cleanup:

```sh
CONFIRM=1 bin/rails writ:cleanup
```

The task scans stored authorization data across the application, including all tenants in multi-tenant mode. These commands do not accept a tenant ID filter.

Cleanup uses `permissions.generated_signature` and `roles.generated_fields` to remove unchanged, tracked defaults that are no longer configured. It preserves:

- Customized or untracked grants.
- Roles with names no longer recognized in definitions, which may have been renamed by a tenant.
- Catalog scopes/conditions referenced by surviving grants.
- Field restrictions needed by surviving grants.

Role names and dependencies are rechecked under locks. A role renamed after scanning is skipped. Cleanup does not regenerate grants or retire entire removed/renamed role definitions; use an explicit application migration for those.

For custom deployment reporting, `Writ::Generator.stale_items(registry)` and `cleanup!(registry:, stale_items:)` expose the same scan and cleanup service.

## Edit attachments or rule schemas

Permission scope and condition attachments support nested attributes, including `_destroy: true`. These changes alter authorization configuration: restrict them to appropriate administrators. Attachment writes participate in the permission save transaction.

Changing a rule's argument schema requires migrating affected stored arguments. Nonempty arguments on a now-argumentless rule are rejected at runtime. The configured invalid-argument mode determines whether evaluation raises or excludes the affected grant.

Callbacks must treat inputs as read-only. Normalized arguments are copied between evaluations. See [Upgrading](upgrading.md) for installations missing provenance columns.
