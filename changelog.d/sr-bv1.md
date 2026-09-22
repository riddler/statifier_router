### Changed

- `StatifierRouter.Broadway.start_link/1` raises `ArgumentError` when `:name` is
  missing or is not an atom, as its options table has always said it would; it
  previously started an unnamed pipeline instead, and passed a
  `{:via, module, term}` name through to Broadway, which accepts one. Give the
  pipeline an atom name, and register it under a registry, if it needs one, by
  that atom rather than by passing the `{:via, module, term}` tuple as `:name`.
