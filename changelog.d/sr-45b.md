### Added

- `StatifierRouter.Broadway`, the Broadway front: a pipeline the host starts in its own supervision tree with any producer, which hands each message to `StatifierRouter.route/3`, partitions messages by the address of the first binding that routes them, and fails rather than acknowledges a message whose routing returns an error or raises.
