# Creating and updating records

[Back to README](../README.md) · [Documentation index](README.md)

Examples use `Access = Writ::Access`. Where shown, `Pundit::NotAuthorizedError` assumes optional Pundit integration; applications can use their own denial handling.

## Creating records

A proposed record cannot use saved SQL membership. `validation` checks create-grant conditions,
declared default/scope `matches:` predicates, and optional creation validators:

```ruby
Writ.configure do |config|
  config.creation_validator do |context:, record:|
    record.organisation_id == context.organisation.id &&
      context.allowed_location_ids.include?(record.location_id)
  end
end
```

Without a validator, an unscoped create grant can authorize when its conditions pass. A validator is responsible for proposed attributes and host constraints. Persisted SQL scopes are not translated into predicates for unsaved objects. Model-specific `creation_validator` declarations run after global declarations and all must pass. A class-level grant check does not validate proposed state.

## Updating records

Authorize the saved record before assignment. Validate the proposed record after assignment.
Neither operation saves, reloads, or clears the caller's changes.

Scopes can use `matches:` alongside their SQL implementation:

```ruby
class AssetPolicy < ApplicationPolicy
  default_scope matches: ->(context, record) {
    record.organisation_id == context.organisation_id
  } do |context|
    Asset.where(organisation_id: context.organisation_id)
  end

  scope :assigned_locations,
        matches: ->(context, record) { context.location_ids.include?(record.location_id) } do |context|
    Asset.where(location_id: context.location_ids)
  end

  role :Technician do
    permission :update, scopes: [:assigned_locations]
  end
end

```

The SQL scope authorizes the saved state. Its matcher validates the supplied proposed record.
The gem does not copy the record, rerun attribute setters, or reconcile stale attributes with the database.
Record freshness and concurrency are host responsibilities.
A parameterized scope uses `matches: ->(context, record, args) { ... }` and receives its validated stored arguments.
PolicyHelpers and `Writ.configure` both accept matchers.

Scopes within each grant intersect. Separate grants form a union, so different grants can authorize the two states.
Conditions run once per grant. The default matcher constrains every proposed grant.
For saved SQL authorization, the registered default scope is applied once per evaluation and
constrains the union of valid grants. Each grant's own scopes still intersect within that grant.
Missing matchers raise `ConfigurationError` by default. Set `config.on_missing_matcher = :warning` to log and skip only the missing proposed-state matcher, or use `:skip` without the warning. Existing matchers still run, false results still deny, and matcher errors still propagate. Neither mode makes an otherwise unconstrained grant validate proposed attributes.
A model with ActiveRecord default scopes also requires a default matcher that represents its applicable constraints.
Keep SQL scopes and matchers equivalent. Test both with representative permitted and denied values.

For update validation, the record must be persisted and its primary key unchanged. It rejects pending changes to loaded associated records.
It supports direct attributes, including foreign keys. Authorize association and nested-record operations separately.
Some association setters write immediately. Do not use those setters to construct a proposed record.

Permission scope and condition attachments support nested attributes, including
`_destroy: true` for removing an existing attachment. The host must authorize changes to these
attachments as permission configuration changes. The association writes remain part of the
permission save transaction.
Matcher exceptions propagate. Matchers must treat the record and context as read-only.

`update_validator` declarations apply only to `Access.validation(subject: record, action: :update, context:)`.
They run after proposed scope matchers. They do not change saved authorization or the generated
`update?` policy method. Global and model-specific update validators run in declaration order.
Every validator must pass. Creation validators use the same global-then-model ordering.

The canonical update flow separates saved authorization from proposed validation. Check the saved
record before assignment, assign the attributes, then validate the changed record before saving:

```ruby
saved = Access.authorization(subject: asset, action: :update, context: user)
raise Pundit::NotAuthorizedError unless saved.allowed?

asset.assign_attributes(attributes)
proposed = Access.validation(subject: asset, action: :update, context: user)
raise Pundit::NotAuthorizedError unless proposed.allowed?
asset.save!
```

Generated Pundit `new?` and `create?` methods use `authorization` for a new record. They check
the create-class grant and its conditions. They do not run matchers or validators. Use
`validation` for a new record with `action: :create` before saving it. A model-class
authorization result also shows grant availability and does not validate proposed attributes.

Field authorization remains separate. Check writable fields against the saved state before assigning request attributes.
When concurrency protection is needed, perform the check and save inside the same transaction
while holding a lock on the record. Acquire the lock before assigning changes; `with_lock`
reloads the saved record before entering the block:

```ruby
asset.with_lock do
  saved = Access.authorization(subject: asset, action: :update, context: user)
  raise Pundit::NotAuthorizedError unless saved.allowed?

  permitted_fields = Access.writable_fields(context: user, record: asset, action: :update)
  submitted_fields = attributes.keys.map(&:to_s)
  raise Pundit::NotAuthorizedError unless permitted_fields == :all || submitted_fields.all? { |field| permitted_fields.include?(field) }

  asset.assign_attributes(attributes)
  proposed = Access.validation(subject: asset, action: :update, context: user)
  raise Pundit::NotAuthorizedError unless proposed.allowed?
  asset.save!
end
```

Lock relevant related records too when their concurrent changes could invalidate the decision.
Callbacks that change authorization-sensitive attributes must run before this check or enforce equivalent constraints themselves.
Both states being permitted does not authorize every business transition between them. Use distinct actions for operations such as approval.
