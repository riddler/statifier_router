### Changed

- On the send-processor shape, `StatifierRouter.SendHandler.perform/2` delivers an immediate `<send>` whose `target` is the reserved `execution` name to the execution its `document` and `key` params address, or refuses it as `{:error, {:send_refused, reason}}`, exactly as `handle_effect/3` does at the executor seam; it no longer answers `{:error, {:unregistered_route, "execution"}}`. The sender's scope is read from the address row its session id names, and a session id that names none is refused as `:unaddressed_sender`.
