### Fixed

- `StatifierRouter.route/3` called inside a host's own transaction no longer loses that transaction when a delivery answers `{:error, reason}`: the delivery rolls back to a savepoint of its own and the host's writes stand.
- An execution-to-execution send refused with a recorded reason no longer takes the sending step down when its `send_refused` ledger row cannot be written: the row rolls back to a savepoint of its own and the refusal is still reported.
