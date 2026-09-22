### Added

- `StatifierRouter.Contracts.undeclared_events/3` lists every `<send>` to the
  reserved execution target whose literal event its receiving document does
  not accept, judged through a host-supplied lookup, with the sends an
  expression or a missing `event` or `document` left unchecked.
- `StatifierRouter.Contracts.undeclared_binding_events/2` lists every binding
  whose event its document does not accept, with the binding's id.
- `StatifierRouter.Contracts.check/3` runs every publish-time check the package
  ships - both `StatifierRouter.Routes` checks and the two above - and answers
  one report under five named keys.

### Changed

- The `statifier` requirement moves to `~> 2.7`, the release carrying
  `Statifier.Chart.check_accepts/2`, which judges a receiver that declares no
  events.
