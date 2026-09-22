# Permission lifecycle

[Back to README](../README.md) · [Documentation index](README.md)

Policy declarations define defaults. Database roles and grants hold each installation or tenant's effective permissions.

## Initial setup

Default-role assignment is a host decision. `as_roleable(scoping_model: true)` generates defaults for the tenant; it does not automatically attach the default role to new users. Add that callback/service explicitly if wanted. Repeating identical `as_roleable` setup is
a no-op, including on subclasses that inherit it. Conflicting setup raises an error.

New organisations receive their configured defaults through `as_roleable(scoping_model: true)`.
`Generator.generate_default_permissions(organisation)` initializes an organisation with no roles.
It rejects organisations that already have roles. Global initialization requires `multi_tenant = false` and an empty role table.

For required, tenant-specific condition arguments, keep the policy registration as a bare or partial
template and provide values when generating each tenant's defaults. Supplied values with the wrong
type or unknown keys fail during configuration loading; missing required values fail when a concrete
permission is saved. This does not mutate the process-wide registry:

```ruby
Writ::Generator.generate_default_permissions(
  organisation,
  condition_arguments: { tenant_ids: { ids: [organisation.id] } }
)
```

The host can disable automatic default generation and call this method from its tenant setup service when
it needs to derive these arguments from tenant state. Missing required values fail the generation transaction.

## Adding permissions

Existing organisations own their grants and fields. Changes to code defaults do not update their configuration.
When a new model or action enters the application, use an explicit data migration:

```ruby
Organisation.find_each do |organisation|
  Writ::Generator.add_permissions(
    organisation,
    permissions: [
      { model: Asset, action: :approve },
      { model: Inspection, action: :read },
      { model: Inspection, action: :create }
    ],
    condition_arguments: { tenant_ids: { ids: [organisation.id] } }
  )
end
```

The selection identifies model/action pairs in the current policy definitions. Unknown or empty selections raise before writes.
For each configured role, the migration adds the selected action only when that role has no grant for that model/action.
All alternative grants for a missing action are created together. Existing scoped or customized grants count as existing permissions.
Repeated migration calls do not add duplicates. The migration preserves other actions, role descriptions, and the organisation's default role.
It creates a configured role when that role is missing. Renamed roles remain unchanged.

New actions can receive missing action-specific field entries. Existing model-wide and action-specific field values remain unchanged.
An explicit model-wide restriction therefore continues to apply to new actions.
Each organisation runs in a transaction. Role locks serialize changes within an existing role.
Migrations use the definitions loaded by the application. Keep those definitions stable while the migration runs.
A newly introduced alternative scope for an existing action needs an explicit host migration because this API preserves existing actions.

`Generator.generate_permissions` remains available for migrations that supply complete grant definitions directly.
It also preserves existing model/action grants and field values. It does not synchronize an organisation with all current defaults.
Use `add_permissions` for migrations that select definitions from policies.

## Retiring generated defaults

The schema includes `permissions.generated_signature` and `roles.generated_fields` for provenance.
Cleanup is a separate, explicit retirement operation. Preview it with `DRY_RUN=1` before using `CONFIRM=1`.
Hosts can call the cleanup service programmatically with a registry and stale-item set when a
deployment task needs its own transaction or reporting. The rake task is a host-facing wrapper
around the same operation.
Cleanup removes unchanged, tracked obsolete defaults for roles still recognized by name in
the registry. A role with an unrecognized name may have been renamed by its tenant; cleanup
preserves it. Retire renamed roles or wholly removed role definitions through an explicit
host migration. Cleanup also preserves custom grants, referenced scope/condition catalog
rows, and field restrictions used by any surviving grant (including unchanged configured
grants). It rechecks role names and field dependencies under locks before deletion.
If a role is renamed after the cleanup scan, its scanned grants and fields are skipped,
including when the new name is another configured role.
It does not regenerate or reset permissions.

## Changing rule schemas

Changing or removing a rule schema requires a host data migration for affected grants.
Runtime checks reject nonempty stored arguments when the rule no longer accepts arguments.
The configured invalid-argument mode determines whether the check raises or excludes that grant.
Callbacks should treat their inputs as read-only. Normalized argument values are copied between evaluations.

For schema changes in existing installations, see [Upgrading](upgrading.md).
