### Added

- `StatifierRouter.Config` takes `:around_delivery`, a module exporting
  `around_delivery/3` or an arity-3 fun handed `(scope, door, work)`, that
  runs a whole delivery inside a context of the host's own: `route/3`'s
  bindings read, `key_refused` rows and deliveries (door `:route`, which
  covers `StatifierRouter.Webhook` and each `StatifierRouter.Broadway`
  message), the Broadway partitioner's bindings read (door `:partition`)
  and the BasicHTTP front's delivery (door `:basichttp`). Left out,
  nothing changes.
