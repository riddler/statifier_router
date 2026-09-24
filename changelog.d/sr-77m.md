### Changed

- `StatifierRouter.Contracts.check/3` and `undeclared_events/3` report a
  delayed `<send>` to the execution target (one that writes `delay` or
  `delayexpr`) with a literal event and a literal `document` as a finding
  with reason `:delay`, without calling the lookup, because such a send
  is refused at run time; before, it passed whenever its receiver
  declared the event.
