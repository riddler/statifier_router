### Added

- A `<send>` whose `target` names no registered route writes one `send_refused` routing-ledger row, under the reserved binding id `execution` and the reason `route`, beside the `{:error, {:unregistered_route, name}}` the sender already heard; a send whose key's scope half names no address row has no scope to record and is reported without a row, and a ledger insert that fails rolls back to its own savepoint rather than to the sending step's.
