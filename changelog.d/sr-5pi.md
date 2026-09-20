### Added

- `StatifierRouter.Config`'s `:persistence_options` carries the
  statifier_persistence snapshot options - `:routes`, `:invoke_types` and
  `:send_types` - onto every create and every step of every delivery.

### Changed

- `StatifierRouter.Config.new/1` refuses a `:store` whose adapter options
  name a repo other than the configuration's own.
