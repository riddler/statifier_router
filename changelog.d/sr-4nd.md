### Added

- A `<send>` whose `target` is the reserved name `execution` delivers to the durable execution at the sender's scope, its `document` param and its `key` param, through the same transaction, dedupe and ledger a binding's delivery uses.
- `StatifierRouter.Delivery.deliver_event/4` delivers one prebuilt event under a delivery plan, the door an execution-to-execution send comes in by.
- `StatifierRouter.Addresses.by_execution/2` answers the address row naming one execution, or `nil`.
- `StatifierRouter.SendHandler.execution_target/0` answers the reserved target name.

### Changed

- `StatifierRouter.Config.new/1` refuses a route registered under the reserved name with `{:reserved_route, name}`, and a binding whose `id` is that name with `{:reserved_binding_id, name}`.
