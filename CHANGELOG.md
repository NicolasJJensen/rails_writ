# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Prepare the 0.2.0 split: `rails_writ` supplies the core; `rails_writ-pundit` supplies Pundit policies, generators, and policy loading.
- Core definitions load from `config/writ/**/*.rb` after initialization and on reload.
- Core installation no longer generates policies or an empty Conditions concern.
- Replace `Writ::PolicyHelpers` with `Writ::Pundit::PolicyHelpers`; add `Writ::Pundit::Policy` and `writ:pundit:*` generators.
- Rebuild documentation around both tenancy modes, complete enforcement examples, and common configuration. Package the linked core guides with the gem.

See [Upgrading](docs/upgrading.md) before moving from 0.1 to 0.2.

## [0.1.0] - 2026-09-21

### Added

- Initial release.
