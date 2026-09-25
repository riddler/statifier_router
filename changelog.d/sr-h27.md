### Added

- `StatifierRouter.Config` takes `:bindings_resolver`, a module implementing the new `StatifierRouter.BindingsResolver` behaviour or an arity-1 fun, answering the bindings of one scope; `route/3`, the Broadway partitioner and `subscribe/3` read its answer for the scope in hand, checked for the reserved and duplicated binding ids as `:bindings` is. It is exclusive with `:bindings`, and `Config.new/1` refuses both with `{:error, {:exclusive_keys, :bindings, :bindings_resolver}}`; left out, `:bindings` is read as before.
