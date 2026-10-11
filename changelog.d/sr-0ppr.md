### Changed

- Names a change to `StatifierRouter.Delivery.deliver_event/4` that
  shipped in 0.11.0 and that the 0.11.0 entry left unsaid: an envelope
  that carries `:run_in_scope` with any value other than `true` or
  `false`, `nil` included, raises `ArgumentError` before anything is
  opened or written, where 0.10.0 ignored the key. Leave the key out, or
  pass a boolean.
- Names how far `run_in_scope: true` reaches, as it has since 0.11.0: a
  delivery that ends the execution resolves the configuration's
  `:on_complete` route in the envelope's `:scope` too, so a completion
  route that a scope in `:route_overrides` overrides is reached. Without
  the key, and with no scope in reach, that route is refused and the
  delivery answers
  `{:error, {:on_complete, name, {:no_delivery_scope, name}}}` with every
  write it made rolled back.
