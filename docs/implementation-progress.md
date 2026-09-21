# Implementation progress

This ledger tracks the test-first phase for the generator and host-policy changes.

## Baseline and runtime

- Repository path: `/Users/nic/Programming/Ruby/Gems/rails_writ`.
- No `AGENTS.md` files were found under the repository.
- The repository directory is not a Git worktree in this environment, so `git status` is unavailable.
- Ruby selected by `bundle exec`: 3.3.6 from rbenv; direct system Ruby is 2.6.10.
- Targeted tests require the configured local PostgreSQL test database. The sandbox cannot open `/tmp/.s.PGSQL.5432`; the same command succeeds with an approved escalated connection.
- Runnable verification command:

  ```sh
  bundle exec rspec spec/lib/writ/contracts/generators_spec.rb spec/lib/writ/contracts/rake_generation_spec.rb
  ```

## Phase 1 red tests

- `generators_spec.rb`: expects generated `ApplicationPolicy` to define explicit CRUD and custom predicate methods and omit `method_missing`/`respond_to_missing?`. Current baseline fails because the template still emits the catch-all implementation.
- `rake_generation_spec.rb`: expects `writ:generate` to resolve a tenant through its model primary key. Current baseline fails because the task calls `find_by(id: record_id)`.

The focused generator/rake run has 14 examples with 3 intentional failures: two generated-policy contracts and the custom-primary-key rake contract. No production files were changed in this phase.

The serialized combined phase1 command completed with **432 examples, 66 failures**. The three failures owned here are the two explicit-policy contracts and the custom-key rake contract. The other 63 failures are tests already present in the shared tree for the registration/proposed-hook/field-resolver/API work owned by the other phase1 agents; they fail with missing methods such as `Configuration.on_missing_matcher=`, DSL `creation_validator`, and registry model-hook methods. Existing query/update behavior outside those new APIs passed in the combined run.

Phase2 generator/rake implementation is now verified by the isolated command above: **15 examples, 0 failures**. The first run exposed a Thor collision because the helper named `raise_invalid_action` was public; moving it below `private` fixed both generator failures. The combined focused run after the shared runtime was reported ready completed with **449 examples, 53 failures**. The 53 failures are outside this ownership: 13 proposed-hook/field-resolver contracts, 6 query regression contracts, 4 batch-field contracts, 11 registry contracts, 2 configuration lifecycle contracts, and 17 policy-helper/DSL setup failures caused by the registry metadata API still absent in that run. The generator and custom-key rake contracts all pass in isolation.

## Ownership and coverage

- This phase owns generator/template/rake regression specs and this ledger.
- Generator and rake production changes remain parent-gated.
- Configuration/DSL/registry/hook tests are owned by `/root/explain_registration`.
- Access and `access/*` runtime tests are owned by `/root/explain_queries`.

Phase2 files changed here: `lib/generators/writ/application_policy/templates/application_policy.rb.tt`, `lib/generators/writ/policy/policy_generator.rb`, `lib/generators/writ/policy/templates/policy.rb.tt`, `lib/tasks/writ.rake`, `lib/generators/writ/initializer/templates/initializer.rb.tt`, `README.md`, and this ledger. The generator now emits explicit CRUD predicates and custom action predicates, rejects aliases that collide with CRUD names, and the rake task uses `model_class.primary_key` for tenant lookup while preserving its missing-record abort behavior.

## Latest full-suite triage

The latest serialized full run completed with **618 examples, 58 failures**. Generator/rake contracts remained green. Exact groups from the final RSpec failure list:

- Configuration rebuild identity: 2 failures (`configuration_spec.rb:134`, `:153`), where replayed validator Procs differ from the expected original Proc.
- Batch field resolver semantics: 2 failures (`batch_fields_spec.rb:35`, `:51`), where record-specific computed fields are not passed through and resolver input remains the shared `name` list.
- Proposed lifecycle/field contracts: failures in `contracts/design_spec.rb` (`:35`, `:83`, `:101`, `:117`, `:136`, `:149`, `:170`, `:185`, `:199`, `:213`, `:229`, `:252`, `:284`) plus lifecycle `contracts/lifecycle_spec.rb:79,106`; these expose resolver `:all`/composition and proposed matcher/validator setup issues, including class-vs-instance matcher invocation.
- Permission migration and relation/filter regressions: failures in `permission_migrations_spec.rb:23,62`, `review_regressions_spec.rb:22,28,35,43,51,56`, and `second_review_spec.rb:51,82`.
- STI proposed validator: 1 failure at `sti_authorization_model_spec.rb:94`.
- Registry: failures at `registry_spec.rb:113,164,661,671,679,793,802,908,964,1014,1033` (the dominant concrete error is missing `register_scope_metadata`, with one `include_global` validation and one condition atomicity case).
- PolicyHelpers/DSL setup: 17 failures at `policy_helpers_spec.rb:44,48,59,65,71,78,84,95,101,112,117,124,131,139,154,168,181`, all failing in the shared setup because `Configuration`/`Registry` does not implement `register_scope_metadata`.

Repository-wide API scan found no old public names `all_user_permissions`, `accessible_fields_for`, or setter-style `creation_validator=`, `field_resolver=`, `update_validator=` outside historical `claude/tasks` prose. Current production `sync_accessible_fields_for_role` is an internal Generator helper, not an obsolete public API. `register_scope_metadata` remains only in parameterized-scope design notes and specs, so those failures are an intentional registry API migration surface for the registry owner.

## Non-DB release checks

- Standalone load passed: `bundle exec ruby -Ilib -e 'require "rails_writ"; abort unless Writ::PermissionAssociations'`.
- Gem build passed to `/private/tmp/rails_writ-0.1.0.gem`; RubyGems emitted only the existing missing-homepage warning.
- README and generated initializer examples match the current `ConfigurationDSL` block API: `field_resolver`, `creation_validator`, `update_validator`, `on_missing_matcher`, `field_default`, `potential_permissions`, and `declared_fields`. The README distinguishes `update_validator`/`update_allowed?` from ordinary persisted `update?`, documents global/model resolver composition through `include_global`, and states global-then-model validators are all evaluated.
- A final source scan found no deleted public API consumers. Remaining `register_scope_metadata` references are historical parameterized-scope notes and registry specs, with no README or generated setup recommending metadata-only registration.

## Final verification

- Full suite after registry/runtime completion and the permission-migration repair: **619 examples, 0 failures**, session `50803`.
- The final generator guard for the reserved `permitted` action was added after that run; generator contracts passed **14 examples, 0 failures**. A final full run including that guard completed **619 examples, 0 failures**, session `44213`.
- The temporary permission-migration signature change was reverted after review: existing model/action rows intentionally suppress newly configured alternatives and preserve host-customized grants. A targeted regression now documents that contract. The earlier full-suite failures at `permission_migrations_spec.rb:36,67` require fixture/state diagnosis rather than widening production behavior.
- Final owned files touched: `lib/generators/writ/policy/policy_generator.rb`, `spec/lib/writ/contracts/generators_spec.rb`, `spec/lib/writ/contracts/permission_migrations_spec.rb`, `README.md`, and this ledger. Earlier owned generator/rake/template files remain listed above; peer-owned runtime, registry, configuration, access, schema, and test files are shared-tree changes outside this list.
- Migration fixture isolation was corrected by installing a fresh registry before forcing the organisation fixture, then explicitly generating defaults after `define_defaults`; this prevents Roleable callbacks from using leaked registry state. The migration spec now has **6 examples, 0 failures**, including an explicit zero-row precondition before creating all alternatives for an absent action.
- Final seeded verification: `bundle exec rspec --seed 20260908` -> **620 examples, 0 failures**, seed `20260908`.
- Post-final-change standalone require passed and gem build passed to `/private/tmp/rails_writ-0.1.0.gem` (only warning: missing homepage).
- Read-only integration audit found and fixed a generator collision: inherited Ruby predicates such as `respond_to?` and `is_a?` could be emitted as zero-argument policy predicates. The guard now derives predicate names from Object/BasicObject/Kernel method sets while retaining ordinary custom actions. Generator contracts: **15 examples, 0 failures**. README documents the reserved inherited predicate names.
- A second full read-only run with seed `20260909` passed: **620 examples, 0 failures**. The DSL audit separately reproduced the missing `on_missing_matcher=` setter; that peer-owned fix is now in progress.
- Final generator collision guard focused red/green: **15 examples, 1 failure** before the guard, then **15 examples, 0 failures** after rejecting inherited Ruby predicate names while retaining `approve`.
- Final combined suite with seed `20260910`: **628 examples, 0 failures**. The count increased after the DSL/schema peer contracts landed.
- Final standalone require and public `Writ.configure { |config| config.on_missing_matcher = :skip }` smoke passed. Final gem build passed to `/private/tmp/rails_writ-0.1.0.gem`; only warning: missing homepage.

## Current host/rake phase

- Added test-first coverage for rejecting an actor model passed to the multi-tenant rake task,
  accepting the configured tenant, accepting an explicit `scoping_model: true` class when no
  default is configured, and omitting the unreachable nullable tenant index from generated roles.
- Red baseline: **19 examples, 2 failures** in the focused rake/generator contracts.
- Focused green after implementation: **19 examples, 0 failures**; the rake-only compatibility
  check is **4 examples, 0 failures**.
- The rake task validates the tenant/scoping model before record lookup or role generation.
  README documents the tenant versus roleable actor distinction and the callable-or-block
  registration contract for public hook APIs.

## Final seeded verification

- Registry/configuration phase: **225 examples, 13 failures** in the initial red phase, then
  **225 examples, 0 failures** after the registry and configuration fixes.
- Runtime/access phase completed with **652 examples, 0 failures** after correcting nested
  includes semantics and condition short-circuit behavior.
- Final unfiltered suite: `bundle exec rspec --seed 20260912` -> **655 examples, 0 failures**.
- Public standalone smoke passed through `require 'rails_writ'`, including DSL
  configuration, matcher setting, condition registration, and callable arity rejection.
- Gem build passed to `/private/tmp/rails_writ-final.gem`; RubyGems emitted only the
  existing missing-homepage warning.
