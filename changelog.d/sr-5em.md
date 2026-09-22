### Added

- `StatifierRouter.Route`, the behaviour a host implements for one named, one-way outbound destination a chart reaches with `<send target="...">`.
- `StatifierRouter.SendHandler`, which serves both shapes a registered send type reaches a host in: `Statifier.Send.Processor` for a live session, and `handle_effect/3` for a process-less host to call from its `StatifierPersistence.Executor`.
- `StatifierRouter.TimerQueue`, the behaviour a host implements for the durable queue a delayed route send is recorded on, keyed by `{scope, send_id}`.
- `StatifierRouter.Config` takes `:route_adapters`, `:route_overrides`, `:send_type` and `:timer_queue`, and `StatifierRouter.Config.route/3` resolves a route name in a scope.
- Giving `:send_type` puts the `Statifier.Send.Types` snapshot for that type into `:persistence_options`, so every create and every step of every delivery declares the host's processor to the engine.

### Changed

- `StatifierRouter.Delivery.deliver/4` answers `{:error, {:reentrant_route, execution_id}}` when a route called at the executor seam calls back into the sending execution, instead of opening a nested step.
