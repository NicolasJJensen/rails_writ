# Contributing

[Back to README](README.md)

Issues and pull requests are welcome on [GitHub](https://github.com/NicolasJJensen/rails_writ).

## Repository layout

| Location | Purpose |
|---|---|
| Root `lib/`, `app/`, and `rails_writ.gemspec` | Core gem |
| `gems/rails_writ-pundit/` | Separately packaged Pundit adapter |
| `spec/` | Core contracts, generated-host tests, and shared Rails test application |
| `gems/rails_writ-pundit/spec/` | Adapter policy, installation, and Rails integration tests |

The development bundle includes the adapter via a local path. The shared dummy app uses it. Separate subprocess tests verify core loading without Pundit, core Rails reloading, and the README workflows for both integrations and tenancy modes.

## Set up the database

Use Ruby 3.3 with the root Rails 7.0 bundle and a running PostgreSQL server. Configure `PGHOST`, `PGUSER`, and `PGPASSWORD` if your local defaults differ.

```sh
bundle install
RAILS_ENV=test bundle exec rake db:create db:migrate
```

The dummy application uses `writ_test`. Generated-host checks use temporary schemas and roll back their fixtures; do not point the suite at production data.

## Run tests and documentation checks

Run both test directories:

```sh
bundle exec rspec spec gems/rails_writ-pundit/spec
```

`bundle exec rake` runs the same combined suite. For adapter-only iteration:

```sh
bundle exec rspec gems/rails_writ-pundit/spec
```

Check local Markdown links, anchors, and Ruby snippet syntax:

```sh
bundle exec ruby bin/check_docs
```

The suite also executes the README's actual policy/context/core-definition examples against generated models, checking permitted and denied records, fields, and proposed changes. Extend those cases when changing the documented setup contracts.

## Compatibility targets

CI resolves dependencies afresh for these combinations and runs the combined suite against PostgreSQL 16:

| Rails | Ruby | Bundle |
|---|---|---|
| 7.0 | 3.1 | `gemfiles/rails_7_0.gemfile` |
| 7.1 | 3.2 | `gemfiles/rails_7_1.gemfile` |
| 7.2 | 3.3 | `gemfiles/rails_7_2.gemfile` |
| 8.0 | 3.3 | `gemfiles/rails_8_0.gemfile` |
| 8.1 | 3.4 | `gemfiles/rails_8_1.gemfile` |

These are configured targets, not a claim about the latest CI outcome. Lockfiles are local and ignored. To test another bundle, select its compatible Ruby first:

```sh
BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle exec rspec spec gems/rails_writ-pundit/spec
```

Core accepts Rails components `>= 7.0, < 9.0`. The adapter requires Pundit `>= 2.5, < 3.0`. Review compatibility before widening those ranges.

## Verify both packages

```sh
bundle exec ruby bin/check_packages
```

This builds both gems in a temporary directory, installs them there without downloading dependencies, checks packaged documentation links, and loads the installed core and adapter in a fresh process. Development dependencies must already be installed.

For distributable files:

```sh
gem build rails_writ.gemspec
cd gems/rails_writ-pundit
gem build rails_writ-pundit.gemspec
```

A version change must update the relevant runtime version and gem specification; the adapter's core dependency must remain compatible. Building does not publish either package.

## Benchmarks and changes

See [Performance and instrumentation](docs/performance.md) for profiling commands and options. Record the initial feature set under Unreleased in [CHANGELOG.md](CHANGELOG.md). Add dated release entries when versions are published. Keep essential setup and both tenancy modes in the main README; reserve separate guides for advanced contracts.
