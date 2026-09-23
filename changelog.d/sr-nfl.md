### Fixed

- A sender's address read that fails while `StatifierRouter.SendHandler` records an unregistered-route or delayed-execution-send refusal no longer takes the sending step down: the read now sits inside the refusal row's savepoint, rolls back to it, and the refusal is still reported, with no ledger row.
