### Changed

- A delayed send to the reserved `execution` target is answered `{:error, {:send_refused, :delay}}` by `StatifierRouter.SendHandler` on both host shapes, and recorded as a `send_refused` ledger row with the reason `delay` when the sender has an address row; at the executor seam it was answered `{:error, {:unregistered_route, "execution"}}` with a `route` row, which named a route no host could register. `t:StatifierRouter.SendHandler.refusal/0` gains `:delay`.
