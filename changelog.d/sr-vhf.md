### Changed

- `t:StatifierRouter.SendHandler.reason/0` gains `{:no_delivery_scope, name}`, the answer `handle_effect/3` gives a send to a route some scope overrides when no delivery scope is in reach.
- `StatifierRouter.SendHandler.perform/2` answers a delayed send with `{:error, {:no_timer_queue, send_id}}` when the configuration names no `:timer_queue`, and a delayed send to an unregistered route with `{:error, {:unregistered_route, name}}` and the same `send_refused` ledger row an undelayed send to it writes.
- `StatifierRouter.SendHandler.perform/2` answers a cancel with the timer queue's own `{:error, reason}` when its `cancel/3` fails, where it answered `:ok` without calling the queue.
