### Added

- `StatifierRouter.Config.new/1` takes `:processor_scope`, a scope string or a zero-arity fun `StatifierRouter.SendHandler` calls per send, so a live `Statifier.Session`'s sends resolve their routes under that scope's `:route_overrides`.
