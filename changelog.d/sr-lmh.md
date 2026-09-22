### Added

- `StatifierRouter.Config`'s `:on_complete` names a registered route an execution's donedata is handed to on the delivery that finishes it, as a `done.execution` event under an idempotency key with no ordinal.
