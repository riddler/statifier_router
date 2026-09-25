### Added

- `StatifierRouter.Config` takes `:on_create` and `:on_step`, a module or a fun the default delivery calls in place of `StatifierPersistence.Executions.create/4` and `step/5`, with the same arguments and return contract, inside the delivery's transaction; left out, the delivery calls statifier_persistence itself as before.
