### Added

- `StatifierRouter.Addresses.reap/2`, a plain function the host schedules, stamps address rows whose execution it first sees finished and deletes those whose longest enabled binding horizon has elapsed; one call examines at most `:limit` rows and returns a `next` cursor.
- `StatifierRouter.Delivery` delivers for `:never` bindings, returning `{:dropped, binding_id, :no_execution}` when the address has no row, and for `:always_new` bindings, creating one execution per delivery with no address row.
