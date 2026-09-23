### Changed

- `StatifierRouter.TimerQueue.schedule/2` now states that a queue holds at most one row per entry `key` (a repeat is answered `:ok` and adds no row), and the behaviour's moduledoc says how a host fires a queued row through `StatifierRouter.Config.route/3` and the route's `deliver/3`.
