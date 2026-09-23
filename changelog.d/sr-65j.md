### Changed

- `StatifierRouter.SendHandler.perform/2` answers a cancel with `{:error, {:no_config, StatifierRouter.SendHandler}}` when the calling process holds no configuration, where it answered `:ok`, and a delayed send the same way, where it answered `{:error, {:delayed_send_unsupported, send_id}}`. Install the configuration with `StatifierRouter.SendHandler.put_config/1` in the process `perform/2` runs in; the moduledoc says why this answer is not reported to the chart.
