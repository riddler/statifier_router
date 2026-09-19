### Added

- `StatifierRouter.Resolver`, the behaviour a host implements to name the chart a new execution of a document starts on; `StatifierRouter.Config.new/1` accepts a module implementing it as `:resolver`, beside the arity-2 fun it already took.
- `StatifierRouter.Resolver.Static.new/1`, a resolver over a map from `{scope, document}` to a compiled machine, for tests and for charts compiled at boot.

### Changed

- When the resolver answers `{:error, reason}`, `StatifierRouter.route/3` returns `{:error, {:unresolved_document, document, reason}}` instead of the resolver's own `{:error, reason}`; a host matching the bare reason matches the wrapped term instead.
