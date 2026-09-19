### Added

- `StatifierRouter.Dedupe.claim/4`, called first in every `StatifierRouter.Delivery` transaction: a message a binding already handled within its dedupe horizon is `{:duplicate, binding_id}`, recorded on the ledger and delivered nowhere; an expired dedupe row counts as absent.
- `StatifierRouter.Dedupe.reap/2`, a plain function the host schedules, deletes expired dedupe rows and returns `{:ok, count}`.

### Changed

- `StatifierRouter.route/3` returns `{:error, :no_message_id}` for an event whose `message_id` is `nil` or empty; a `nil` one was `{:error, {:invalid_event, event}}` before, and an empty one was routed.
