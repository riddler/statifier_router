### Added

- `StatifierRouter.Resolver`, the behaviour a host implements to name the chart a new execution of a document starts on; `StatifierRouter.Config.new/1` accepts as `:resolver` a module implementing it or an arity-2 fun.
- `StatifierRouter.Resolver.Static.new/1`, a resolver over a map from `{scope, document}` to a compiled machine, for tests and for charts compiled at boot.
- `StatifierRouter.route/3` returns `{:error, {:unresolved_document, document, reason}}` when the resolver answers `{:error, reason}` for a document: the delivery's transaction rolls back, so nothing is created and no row is written.
