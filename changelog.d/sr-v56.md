### Added

- `StatifierRouter.Delivery`, the default delivery module: for a binding whose `create` is `:if_absent`, it gets or creates the execution an address names and steps the event into it in one transaction on the host's repo, and returns `created_and_delivered`, `delivered` or `dropped: finished`.
- `StatifierRouter.Config.new/1` takes `:store`, `:executor`, `:resolver` and `:chart_resolver`, the four options `StatifierRouter.Delivery` requires.

### Changed

- `StatifierRouter.Config.new/1` no longer requires `:delivery`; it defaults to `StatifierRouter.Delivery`.
