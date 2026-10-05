### Added

- `StatifierRouter.Config` takes an optional boolean `:wrap_target`, given
  only beside `:around_delivery`: set to `true`, a `<send>` to the
  execution target on the send-processor shape, or from a step the router
  did not drive, is delivered inside the wrapper too, under the new door
  `:target` and the sender's scope, while one sent from a step a wrapped
  door drove is still wrapped once, by that door. Left out, or `false`,
  nothing changes.
