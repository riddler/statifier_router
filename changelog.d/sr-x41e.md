### Added

- `StatifierRouter.Delivery.deliver_event/4` reads an optional boolean
  `:run_in_scope` in its envelope: set to `true`, the step the delivery
  drives resolves its routes in the envelope's `:scope`, so a host's own
  job that delivers an event back in - as the README's "Sending from a
  durable execution" recipe does - reaches a route that a scope in
  `:route_overrides` overrides, where it was refused as
  `{:no_delivery_scope, name}`. The scope is set for the length of the
  call and any scope the calling process held before is put back. Left
  out, or `false`, nothing changes; any other value raises
  `ArgumentError` before anything is written.
