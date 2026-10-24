# Advanced write flows

The [README](../README.md#creating-and-updating-records) covers ordinary create/update actions, field filtering, and Rails error responses. These additional contracts apply in both tenancy modes.

## Saved state and proposed state

`authorization` checks saved SQL membership. `propose` prepares the proposed record, checks fields and proposed-state rules, and returns a `ProposalResult` containing `record` and `result`. It supports ordinary writes and STI type changes without saving.

The lower-level `validation` method checks the current in-memory attributes using scope validators and applicable lifecycle validators. It requires a record whose Ruby class agrees with its STI discriminator; use `propose` to construct a different subtype. Neither method runs ordinary ActiveRecord validations or saves the record.

Different grants may allow the saved and proposed states. That alone does not authorize every transition between them. Use lifecycle validators for transition rules; an application can also define a separate action when it wants a distinct permission for an operation such as approval.

`authorize_proposed!` infers create/update and checks Rails dirty fields when `attributes:` is omitted. Dirty tracking includes application-assigned changes and excludes unchanged submitted values. Supply `attributes:` when every submitted key must be checked. The helper does not replace the initial Pundit `authorize` call or satisfy `verify_authorized` on its own.

## Changing an STI type

Suppose `Truck` and `Van` inherit from `Vehicle`, and their policies inherit from `VehiclePolicy`. The common update grant can authorize both sides of a Truck-to-Van change. The role's writable fields must also permit the inheritance column, normally `type`.

The controller uses the usual update action:

```ruby
class VehiclesController < ApplicationController
  before_action :set_vehicle, only: :update

  def update
    authorize @vehicle, :update?
    @vehicle = authorize_proposed!(
      @vehicle, attributes: permitted_attributes(@vehicle)
    )
    @vehicle.save!
    redirect_to vehicle_path(@vehicle)
  end

  private

  def set_vehicle
    @vehicle = Vehicle.find(params[:id])
  end
end
```

If the permitted input changes `type` from `"Truck"` to `"Van"`, Writ returns a Van instance representing the same row. No conversion keyword is needed. Keep the returned instance: assigning `type` alone does not change a Ruby object's class.

Writ resolves the requested class using the model's STI configuration and restricts it to the same hierarchy and table. Invalid or unrelated types are not accepted. Custom inheritance columns and Rails STI names use the same flow.

For a persisted conversion, Writ checks:

- Update authority over the original saved record, including its scopes and fields.
- An applicable update grant for the destination model and its proposed-state scopes.
- Destination field restrictions for the submitted changes.
- The original and destination lifecycle validators, with shared ancestors run once.

The row remains persisted, so this requires update authority, not a destination create grant. For a new record, Writ checks the final subtype's create authority and proposed-state rules instead. `save!` then runs the final subtype's normal model validations and callbacks.

When creation uses subtype-specific permissions, build the requested subtype in the usual `before_action` before the initial Pundit `authorize` call. That initial check uses the instance's current class. A shared Vehicle create grant already applies to its registered descendants; the core proposal does not require an additional base-class create grant.

The same flow works with preassigned values:

```ruby
@vehicle.assign_attributes(type: "Van", name: "Delivery vehicle")
@vehicle = authorize_proposed!(@vehicle)
@vehicle.save!
```

Here the checked fields come from dirty tracking. The proposed instance retains the original attribute baseline, so transition validators can compare saved and proposed values:

```ruby
Writ.configure do
  update_validator model: Vehicle do |record:, errors:, **|
    column = record.class.inheritance_column
    if record.will_save_change_to_attribute?(column) &&
       record.attribute_in_database("status") != "draft"
      errors.add(column, :not_permitted, message: "can only be changed while the vehicle is a draft")
    end
  end
end
```

This validator receives the proposed Van, including when registered on the source or a shared ancestor. Source-specific validators must account for a different destination class if the application allows conversion.

Single-tenant and tenant applications use this same mechanism. A default tenant scope inherited from Vehicle constrains the original and proposed records; changing the type does not permit moving the record into another organisation.

If the proposal fails, the adapter's `ProposedAuthorizationError#record` holds the proposed instance and errors. Recover that instance in the shared rescue handler as shown in [Rendering errors](../README.md#rendering-errors). Core callers use `proposal.record` and `proposal.result` directly. Neither API persists a rejected proposal.

## Concurrent edits

When concurrent edits could invalidate authorization, lock before assignment. For a Pundit controller:

```ruby
@asset.with_lock do
  authorize @asset, :update?
  @asset = authorize_proposed!(@asset, attributes: permitted_attributes(@asset))
  @asset.save!
end
```

`with_lock` reloads the saved record before entering the block. Lock related records too when their changes could invalidate the decision. Keep the user and selected tenant stable for the entire operation.

For the core API, use `authorization` and `propose` inside the same lock, then save the returned record. See the [core example](../README.md#using-the-core-api).

## Associations and callbacks

- Proposed validation supports direct attributes, including foreign keys. For `:update`, persisted primary keys must remain unchanged.
- For `:update`, pending changes to loaded associated records are rejected. Authorize and validate nested records separately.
- Some association setters write immediately. Do not use them to build an unsaved proposal.
- Callbacks that change authorization-sensitive attributes must execute before the proposed check or enforce equivalent rules themselves.

A tenant transfer is a separate operation: the ordinary tenant default scope denies a change to another organisation. The application must explicitly authorize both sides of a transfer.

## Scope validation and errors

Each scope has a SQL `query` and, when proposed writes need checking, a `validate` callback. Keep them equivalent. ActiveRecord model-level default scopes also need an equivalent Writ default validator when their restrictions must constrain proposals.

The validator receives the actual record and an isolated `ActiveModel::Errors` collection:

```ruby
# Inside Writ.configure
scope :draft, model: Asset do
  query { Asset.where(status: "draft") }
  validate do |asset, errors|
    errors.add(:status, :not_permitted, message: "must remain a draft") unless asset.status == "draft"
  end
end
```

Treat the record, context, and arguments as read-only. Add errors to the supplied collector, not `asset.errors`. This prevents a rejected alternative grant from contaminating a successful decision.

Within a grant, every scope must pass. Any successful grant permits the proposal, subject to the default boundary and lifecycle validators. On total failure, a sole eligible grant's errors or identical errors shared by all eligible failed grants become the public result; otherwise Writ returns a generic base error. An inactive grant whose condition failed never evaluated the proposal, so it does not erase useful field errors from eligible grants. All individual failures remain available in `result.denied_grants` for diagnostics.

Core `validation` leaves the live record's errors untouched. `result.apply_errors_to(record)` imports the final errors and replaces only earlier Writ-owned error objects. Applying a later successful result removes those previous Writ errors while preserving unrelated errors. The adapter helper performs this step automatically.

`result.errors` and each denied grant's `errors` contain immutable snapshots with `attribute`, `type`, and `options`. Use normal `record.errors.full_messages`, `to_hash`, or `details` after applying them. Avoid returning internal grant diagnostics to clients.

## Lifecycle validators

Authorization-specific rules applying after scope validation can use lifecycle hooks:

```ruby
Writ.configure do
  update_validator model: Asset do |context:, record:, errors:|
    unless context.may_approve? || !record.will_save_change_to_approved_at?
      errors.add(:approved_at, :not_permitted, message: "cannot be changed")
    end
  end
end
```

`creation_validator` works the same way for creates. Global validators run before model-specific validators, after a matching grant is found. With rule inheritance, model validators run ancestor-first. Explicit `errors:` selects error-collection behavior; the return value is ignored. Existing callbacks accepting only `context:` and `record:` use their boolean return value.

Ordinary model invariants belong in ActiveRecord validations and run at `save!`. Scope and lifecycle callback exceptions propagate; they are not converted into user validation errors.

Missing proposed validators/matchers raise by default. The advanced `:warning` and `:skip` modes omit the missing check; they do not implement an equivalent restriction. See [failure modes](reference.md#failure-modes).
