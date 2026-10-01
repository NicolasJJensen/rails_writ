# Changelog

## [Unreleased]

### Added

- Database-backed roles and permissions for single-tenant and multi-tenant Rails applications.
- Record scopes, conditions, field permissions, and validation of proposed changes.
- Generators for authorization models, migrations, and configuration.
- Permission definitions in `config/writ/**/*.rb`, loaded after initialization and rebuilt on reload.
- Optional `rails_writ-pundit` integration with policies, controller helpers, and policy generators.
