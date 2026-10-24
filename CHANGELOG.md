# Changelog

## [Unreleased]

### Added

- Database-backed roles and permissions for single-tenant and multi-tenant Rails applications.
- Record scopes with separate query and validation callbacks, structured field errors, conditions, and role-level field permissions.
- Inferred tenant configuration with automatic filtering of assigned roles and permissions.
- Generators for authorization models, migrations, and configuration.
- Permission definitions in `config/writ/**/*.rb`, loaded after initialization and rebuilt on reload.
- Optional `rails_writ-pundit` integration with policies, permitted attributes, proposed-write helpers, and policy generators.
- Inherited STI permissions, scopes, field settings, and validators through policy inheritance or core rule declarations.
- Automatic STI type changes in proposed writes, checked against original and destination authority before saving.
