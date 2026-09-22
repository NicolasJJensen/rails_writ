# Field permissions

[Back to README](../README.md) · [Documentation index](README.md)

Field rules determine which names your serializers and forms may expose or accept. They are separate from action authorization. Examples use `Access = Writ::Access` and an application-supplied `actor`.

## Declaring fields

```ruby
role :Technician do
  permission :read
  permission :update, scopes: [:own]
  accessible_fields [:name, :description], action: :read
  accessible_fields [:name], action: :update
end

Access.readable_fields(context: actor, record: asset)
Access.writable_fields(context: actor, record: asset, action: :update)
```

The result is `:all` or an array of string field names. No effective grant means `[]`. Only roles with matching grants contribute. For a persisted record, conditions and record scopes are evaluated before fields are combined. Passing a model class checks grant availability only. Field names may represent computed presentation keys; the gem does not introspect a serializer.

`accessible_fields [...]` with an omitted or `nil` action is shorthand for four declarations:
`:create`, `:read`, `:update`, and `:delete`. Pass an explicit action as a String or Symbol, such
as `action: :read` or `action: "publish"`, to configure one action. Each action has an independent field list. A later declaration
**replaces** that action's list; it does not union it with the earlier list:

```ruby
accessible_fields [:name]
accessible_fields [:name, :description], action: :read
# create: ["name"], read: ["name", "description"], update: ["name"], delete: ["name"]
```

A later shorthand replaces all four CRUD lists but leaves explicitly configured custom
actions unchanged. The shorthand does not configure custom actions such as `:approve`.
The default is `:all`; configure `field_default = []` for explicit opt-in fields.
Explicit `:all`/stored `nil` is unrestricted, and `[]` means no fields. Missing action
entries use the configured default. Different effective roles still combine their grants
and fields by union. If any effective grant contributes `:all`, the combined value passed to
field resolvers is `:all`; under this union semantics, a `:all` field grant cannot be narrowed
by another grant. Resolvers should preserve `:all` unless the application deliberately owns a
replacement policy for the complete result.

`declared_fields` remains metadata only and does not authorize a record. It returns
the union of declared action fields, or `:all` if any declared action is unrestricted.
Class arguments follow the configured STI resolver; string arguments address stored model
names directly. Existing database arrays/nil retain their legacy all-action meaning.
Generation preserves those existing host-owned values; the new shorthand applies to new
definitions and does not rewrite existing roles.

## Dynamic field resolvers

For dynamic or nested presentation conventions, register a global field resolver in the configuration DSL, or register a model resolver in a policy. A model resolver includes the global resolver only when `include_global: true`:

```ruby
Writ.configure do |config|
  config.field_resolver do |context:, action:, record:, fields:|
    # Return :all or a list of names understood by your serializer/form.
    fields
  end
end
```

Each model, including the global resolver, starts with one resolver. Registering a second
resolver for the same model raises so that configuration load order cannot silently change
field access. Use `append: true` when independent rules should both apply; they run in
declaration order and each receives the fields returned by the prior resolver. Use
`replace: true` when the later declaration intentionally discards the existing resolver
chain.

```ruby
class AssetPolicy < ApplicationPolicy
  field_resolver do |fields:, **|
    fields == :all ? :all : fields + ["display_name"]
  end
end

Writ.configure do |config|
  config.field_resolver(model: Asset, append: true) do |context:, fields:, **|
    if fields == :all
      :all
    elsif context.external_user?
      fields - ["internal_cost"]
    else
      fields
    end
  end
end
```

Use composition when each resolver expresses a separate rule. A replacement is appropriate
when an application deliberately takes ownership of the complete result:

```ruby
Writ.configure do |config|
  config.field_resolver(model: Asset, replace: true) do |context:, **|
    context.admin? ? :all : []
  end
end
```

## Applying field decisions

A serializer should intersect its own field selection with readable fields. A command/form should reject or filter input keys against writable fields and separately authorize the action. Nested associations must be authorized independently. Neither field query mutates a record, serializes data, or permits parameters. Hoist model-wide decisions outside per-record loops where appropriate; record-aware fields can require membership queries per grant. No global permission-result cache is used.

For collection rendering, see [Batch field access](performance.md#batch-field-access).
