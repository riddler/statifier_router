### Added

- `StatifierRouter.subscribe/3` and `StatifierRouter.cancel/2` subscribe one execution's `<invoke>` to a binding for the lifetime of the invoking state, and undo it (ADR-0007).
- `StatifierRouter.SourceInvoke` maps an invoke's start and the engine's cancellation onto those two calls, for a host's invoke handler to delegate to.
- `StatifierRouter.Migrations.V02` adds the subscription table those calls write. A host already running V01 migrates to it with `StatifierRouter.Migrations.up(from: 2)`, since `from:` names the first version the host has not run and the walk includes it.
- `StatifierRouter.Schema.Subscription`: the Ecto schema over the subscription table.
