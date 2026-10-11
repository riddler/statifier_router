### Fixed

- A `StatifierRouter.route/3` called from a route after a nested
  `StatifierRouter.Delivery.deliver_event/4` inside it is refused as
  `{:error, {:reentrant_route, execution_id}}`; the nested step's exit
  had cleared the route mark, so the call was let through and stepped the
  sending execution from a position not yet written.
