### Fixed

- A route that calls `StatifierRouter.Delivery.deliver_event/4` keeps its
  route mark after that nested step: `StatifierRouter.route/3` (and
  `StatifierRouter.Delivery.deliver/4`) and
  `StatifierRouter.BasicHTTP.Front.handle/3` called in-process from the
  rest of that route are refused as
  `{:error, {:reentrant_route, execution_id}}`, and
  `StatifierRouter.SendHandler.sending_execution/0` reads the sending
  execution there; the nested step's exit had cleared the mark, so they
  were let through (stepping the sending execution from a position not
  yet written) and `sending_execution/0` read `nil`.
