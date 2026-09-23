### Changed

- `StatifierRouter.SendHandler.handle_effect/3` refuses a send or a delayed send to a route that some scope in `:route_overrides` overrides, when no delivery scope is in reach, with `{:error, {:no_delivery_scope, name}}` instead of sending it to the registered configuration. The send-processor shape (`perform/2`) is unchanged and still resolves such a send to the registered configuration. A route no scope overrides resolves as before on both shapes.
- `StatifierRouter.SendHandler.sending_execution/0` also names the sending execution while the timer queue's `schedule/2` and `cancel/3` run at the executor seam, so a `StatifierRouter.route/3` called from host queue code there is refused with `{:error, {:reentrant_route, execution_id}}`.
