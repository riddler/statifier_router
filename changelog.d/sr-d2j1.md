### Security

- The router's own Ecto query log no longer prints the BasicHTTP location
  token at `:debug`: the front's lookup, the location insert at create
  and `StatifierRouter.BasicHTTP.rotate_location/2` run with `log: false`.
  The query telemetry event still carries the token, as does the
  execution's persisted state; never run a production repo at `:debug`.
