### Added

- A `<send>` whose `target` names no registered route writes one `send_refused` routing-ledger row, under the reserved binding id `execution` and the reason `route`, beside the `{:error, {:unregistered_route, name}}` the sender already heard; a sender with no address row has no scope and is reported without a row, and a ledger write that fails cannot roll the sending step back.
