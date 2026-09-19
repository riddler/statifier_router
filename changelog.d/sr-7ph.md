### Added

- `StatifierRouter.route/3` routes one event through the configured bindings and returns one outcome per enabled binding for the event's source, in configuration order, writing a routing ledger row for each key_refused and reporting each no_match as the telemetry event `[:statifier_router, :route, :no_match]`.
- `StatifierRouter.Config.new/1` takes `:bindings`, built through `StatifierRouter.Binding.new/1` with a duplicate binding id refused, and an optional `:delivery` module that `route/3` hands each delivery to, defaulting to `StatifierRouter.Delivery`.
