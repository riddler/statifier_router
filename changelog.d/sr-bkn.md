### Added

- `StatifierRouter.Routes.unregistered/2` lists every `<send>` of the
  configuration's send type whose literal `target` names no registered route,
  with the sends an expression left unchecked, for a host's own publish step.
- `StatifierRouter.Routes.unsupported_types/2` lists every `<send>` whose
  literal `type` is outside the set the configuration registers.
