# Architecture Decision Records

| # | Decision | Status |
|---|---|---|
| [0001](0001-bindings.md) | A binding is host configuration with a fixed key set (`id`, `source`, `selector`, `match`, `key`, `document`, `event`, `data`, `create`, `dedupe`, `order`, `enabled`); `match` and `key` are predicator programs compiled once and evaluated over the adapter-normalized event; `match` holds only on exactly `true` and `:undefined` means not for this binding; a key that is not a non-empty string is a refusal recorded against the binding; one event reaches every binding whose match holds; `data` is a projection; `mode`, `batch` and `window` are reserved and refused by name | proposed |
| [0002](0002-addressing.md) | One table, the address, maps `(scope, document, key)` to an `execution_id`, unique on the triple; `document` is the stable document id, never a chart hash; `scope` is an opaque host string compared only for equality; the router mints an opaque execution id at create, never derived from the key, and the row records it; a host resolver answers which chart a new execution starts on; a finished execution keeps its row for the longest dedupe horizon of any enabled binding naming its document, counted from when the package first saw it terminal; `reap/2` is a plain function the host schedules; an `always_new` delivery writes no row | proposed |

New ADRs: next number, same three-section format (Context, Decision,
Consequences), each a new file `NNNN-<slug>.md` at `Status: proposed` with a
row in the table above. Pick the number against a freshly fetched remote. A
later change to a merged record is a Note or an Amendment appended at the
foot of the file; the body above it is not edited.

A bare `ADR-NNNN` cites this repository's own records; a cross-repo citation
carries the owning repo's beads prefix: `sp-ADR-NNNN` is statifier_persistence's
ADR-NNNN and `st-ADR-NNNN` is statifier-ex's.
