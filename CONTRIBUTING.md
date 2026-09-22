# Contributing

[Back to README](README.md)

Bug reports and pull requests are welcome on [GitHub](https://github.com/NicolasJJensen/rails_writ).

## Development setup

Install PostgreSQL and the Ruby version required by your chosen bundle, then run:

```sh
bundle install
RAILS_ENV=test bundle exec rake db:create db:migrate
bundle exec rspec
```

The test app uses `writ_test` in local PostgreSQL. Contract specs cover query composition, projections, custom keys/contexts, callback retries, registry rebuilding, generators, field decisions, and cleanup provenance. Host integrations should also test their own serializers, validators, and permission-source tenant isolation. Validate supported Ruby/Rails combinations before broadening version claims.

## Compatibility checks

The CI workflow has frozen baselines for the committed root and Rails 8.1 lockfiles,
using Ruby 3.3 and 3.4 respectively. These lockfiles include Linux platforms for CI.
A separate fresh-resolution matrix updates dependencies for Rails 7.0/7.1/7.2/8.0/8.1
on Ruby 3.1/3.2/3.3/3.3/3.4 respectively, with PostgreSQL. It intentionally updates even
the Rails 8.1 lockfile within that job, without changing the committed baseline.
These are test targets; a configured matrix is not evidence that every job has passed.
Each job runs the full suite, including generated-host lifecycle,
real class unloading/eager loading, and optional Pundit integration. Pundit is only a
development dependency. Rails/Ruby minimums follow the [Rails upgrade guide](https://guides.rubyonrails.org/upgrading_ruby_on_rails.html);
test framework versions follow [RSpec Rails compatibility guidance](https://github.com/rspec/rspec-rails).

Run an alternate bundle locally, for example:

```sh
BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile bundle exec rspec
```

## Benchmarks

See [Performance and instrumentation](docs/performance.md#profiling) for the benchmark command and options.

## Compatibility policy

Runtime dependencies accept Rails components from 7.0 through 8.x (`< 9.0`). Future major
versions require a compatibility review before widening that range. Railties remains an
installation dependency; standalone ActiveRecord hosts can load the core without booting
Rails. The package includes the MIT license.
