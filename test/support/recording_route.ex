defmodule StatifierRouter.RecordingRoute do
  @moduledoc """
  A route adapter for this package's own tests: it reports every call to
  the pid in its own configuration and answers from that configuration,
  handing nothing anywhere.

  The message is `{:routed, route_config, event, key}`, so a test reads
  back the configuration the adapter was given - which is what a per-scope
  override changes - beside the event and the composed idempotency key.
  `:answer` in the configuration is what `deliver/3` returns, defaulting to
  `:ok`. Test-only support code, not part of the package's public API.
  """

  @behaviour StatifierRouter.Route

  @impl StatifierRouter.Route
  def deliver(%{pid: pid} = route_config, event, key) do
    send(pid, {:routed, route_config, event, key})

    case Map.get(route_config, :answer, :ok) do
      fun when is_function(fun, 0) -> fun.()
      answer -> answer
    end
  end
end
