### Added

- `StatifierRouter.Config` takes `:execution_id`, a module exporting `execution_id/3` or an arity-3 fun of `(scope, document, key)` answering a non-empty string, which the default delivery mints each new execution's id with; that id is the one on the address row, the created execution and the ledger. An answer that is not a non-empty string raises `ArgumentError`. Left out, the id is a UXID with the prefix `ex`, as before.
