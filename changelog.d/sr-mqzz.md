### Added

- `StatifierRouter.Config.new/1` takes `:send_handlers`, a map from each send type the host serves itself to its processor module, merged with `:send_type` into the one `send_types:` snapshot every delivery carries, so `StatifierRouter.Contracts.check/3` no longer reports the host's own types under `:unsupported_types`; left out, the snapshot is built from `:send_type` alone as before.
