### Added

- `StatifierRouter.Broadway`, the Broadway front: a pipeline the host starts in its own supervision tree with any producer, which hands each message to `StatifierRouter.route/3`, partitions each message by the address of the first enabled `order: :by_key` binding for its source whose `match` holds and whose `key` resolves, or by its message id when no such binding addresses it, and fails rather than acknowledges a message whose routing returns an error or raises.
