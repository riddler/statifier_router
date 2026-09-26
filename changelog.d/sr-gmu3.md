### Fixed

- `StatifierRouter.Broadway`'s partitioner no longer takes the producer down when a `:bindings_resolver` answers something that is not a list of bindings: it partitions that message by its message id, and `route/3` raises the `ArgumentError` in `handle_message/3`, where Broadway fails the message.
