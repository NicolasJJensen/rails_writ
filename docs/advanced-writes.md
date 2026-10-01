# Advanced write flows

The [README](../README.md#creating-and-updating-records) covers ordinary create/update actions, field filtering, and Rails error responses. These additional contracts apply in both tenancy modes.

## Saved state and proposed state

`authorization` checks saved SQL membership. `validation` checks the current in-memory attributes using scope validators and applicable lifecycle validators. Neither saves or reloads the record.

Different grants may allow the saved and proposed states. That alone does not authorize every transition between them. Give operations such as approval a distinct action and explicit business rules.

`authorize_proposed!` infers create/update and checks Rails dirty fields when `attributes:` is omitted. Dirty tracking includes application-assigned changes and excludes unchanged submitted values. Supply `attributes:` when every submitted key must be checked. The helper does not replace the initial Pundit `authorize` call or satisfy `verify_authorized` on its own.

## Concurrent edits

When concurrent edits could invalidate authorization, lock before assignment. For a Pundit controller:

```ruby
@asset.with_lock do
  authorize @asset, :update?
  authorize_proposed!(@asset, attributes: permitted_attributes(@asset))
  @asset.save!
end
```

`with_lock` reloads the saved record before entering the block. Lock related records too when their changes could invalidate the decision. Keep the user and selected tenant stable for the entire operation.

For the core API, use `authorization`, then assign attributes and call `validation` with `submitted_fields:` inside the same lock. See the [core example](../README.md#using-the-core-api).

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

Within a grant, every scope must pass. Any successful grant permits the proposal, subject to the default boundary and lifecycle validators. On total failure, a sole grant's errors or identical errors shared by all failed grants become the public result; otherwise Writ returns a generic base error. Individual failures remain available in `result.denied_grants` for diagnostics.

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

`creation_validator` works the same way for creates. Global validators run before model-specific validators, after a matching grant is found. Explicit `errors:` selects error-collection behavior; the return value is ignored. Existing callbacks accepting only `context:` and `record:` use their boolean return value.

Ordinary model invariants belong in ActiveRecord validations and run at `save!`. Scope and lifecycle callback exceptions propagate; they are not converted into user validation errors.

Missing proposed validators/matchers raise by default. The advanced `:warning` and `:skip` modes omit the missing check; they do not implement an equivalent restriction. See [failure modes](reference.md#failure-modes).
