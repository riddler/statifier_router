### Added

- `StatifierRouter.BasicHTTP.rotate_location/3` rotates a location as
  `rotate_location/2` does and, with `session:` naming the host's running
  `Statifier.Session`, re-stamps that session so its chart reads the new
  location: it answers `{:ok, location}`, `{:error, {:no_address, id}}` as
  before, or `{:error, {:session_not_restamped, location, reason}}` when the
  token moved and the session refused, with `:replace_send_type_unavailable`
  on a statifier before 2.13.0. The statifier requirement stays `~> 2.10`,
  and `rotate_location/2` answers as before.
