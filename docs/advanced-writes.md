# Advanced write flows

[README](../README.md#usage) contains the ordinary create/update examples for both tenancy modes. These additional contracts apply with either the core API or Pundit adapter.

## Saved state versus proposed state

`authorization` checks saved membership. `validation` evaluates the record's current in-memory attributes against matchers and applicable lifecycle validators. Neither saves, reloads, or clears changes.

Different grants may allow the saved and proposed states. That does not authorize every transition between them. Give operations such as approval a distinct action and explicit business rules.

## Lock before assignment

When concurrent edits could invalidate authorization, acquire the lock before reading fields or assigning changes:

```ruby
asset.with_lock do
  saved = Writ::Access.authorization(subject: asset, action: :update, context: context)
  raise AccessDenied unless saved.allowed?

  fields = Writ::Access.writable_fields(context: context, record: asset, action: :update)
  input = attributes.stringify_keys
  raise AccessDenied unless fields == :all || (input.keys - fields).empty?

  asset.assign_attributes(input)
  proposed = Writ::Access.validation(subject: asset, action: :update, context: context)
  raise AccessDenied unless proposed.allowed?
  asset.save!
end
```

`AccessDenied` is the application exception defined in the README's core example. Adapter applications can use `Pundit::NotAuthorizedError`. Neither gem chooses HTTP responses for your application.

`with_lock` reloads the saved record before entering the block. Lock relevant related records too if their changes could invalidate the decision. Keep the context stable for the operation; multi-tenant applications must keep the selected tenant stable as well.

## Associations and callbacks

- Proposed validation supports direct attributes, including foreign keys. It requires an unchanged primary key for persisted records.
- Pending changes to loaded associated records are rejected. Authorize nested records separately.
- Some association setters write immediately. Do not use them to build an unsaved proposal.
- Callbacks that change authorization-sensitive attributes must execute before validation or enforce equivalent rules themselves.

For tenant transfers, changing `organisation_id` is not an ordinary permitted edit: the current tenant matcher normally denies it. An application-specific transfer operation must authorize both sides and preserve its own invariants.

## Matcher and validator behavior

Keep default and per-grant matchers equivalent to SQL scopes. ActiveRecord default scopes also need an equivalent default matcher when validating proposed state.

Missing matchers raise by default. `:warning` and `:skip` omit the missing constraint; they do not create an equivalent validation rule. Existing false matchers still deny, and matcher exceptions propagate.

Create/update validators run after applicable matchers, global before model-specific. Every validator must pass. They apply only to `validation` for the matching action, not to saved checks or adapter predicates. Matchers and validators must treat the record and context as read-only.
