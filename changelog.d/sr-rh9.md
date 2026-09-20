### Changed

- `StatifierRouter.Addresses.reap/2` deletes an address row whose execution
  the store no longer holds instead of refusing with
  `{:error, :execution_not_found}`, so one such row no longer ends every
  sweep that reaches it.
