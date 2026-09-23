### Changed

- `StatifierRouter.SendHandler.perform/2` records a delayed send on the configured `StatifierRouter.TimerQueue` under the same composed key and with the same row the executor seam writes, and performs a planned cancel through that queue's `cancel/3`; it no longer answers a delayed send with `{:error, {:delayed_send_unsupported, send_id}}`, and that reason is dropped from `t:StatifierRouter.SendHandler.reason/0`.
