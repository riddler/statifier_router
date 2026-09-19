# Architecture Decision Records

| # | Decision | Status |
|---|---|---|
| [0001](0001-bindings.md) | A binding is host configuration with a fixed key set (`id`, `source`, `selector`, `match`, `key`, `document`, `event`, `data`, `create`, `dedupe`, `order`, `enabled`); `match` and `key` are predicator programs compiled once and evaluated over the adapter-normalized event; `match` holds only on exactly `true` and `:undefined` means not for this binding; a key that is not a non-empty string is a refusal recorded against the binding; one event reaches every binding whose match holds; `data` is a projection; `mode`, `batch` and `window` are reserved and refused by name | proposed |

New ADRs: next number, same three-section format (Context, Decision,
Consequences), each a new file `NNNN-<slug>.md` at `Status: proposed` with a
row in the table above. Pick the number against a freshly fetched remote. A
later change to a merged record is a Note or an Amendment appended at the
foot of the file; the body above it is not edited.

A bare `ADR-NNNN` cites this repository's own records; a cross-repo citation
carries the owning repo's beads prefix: `sp-ADR-NNNN` is statifier_persistence's
ADR-NNNN and `st-ADR-NNNN` is statifier-ex's.
