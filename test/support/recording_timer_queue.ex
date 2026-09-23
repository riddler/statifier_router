defmodule StatifierRouter.RecordingTimerQueue do
  @moduledoc """
  A durable timer queue for this package's own tests, standing in for the
  host's. It keys its rows on `{scope, send_id}` - st-ADR-0054's
  cancellation key, which ADR-0005 decision 5 requires the queue to be
  keyed on - and holds them in the calling process, which is the process
  one delivery and its executor seam both run in.

  Keying on the pair is the whole point of this stand-in: a queue keyed on
  the send id alone would answer a cancel by deleting every execution's
  row under that id, and a generated send id recurs in every execution on
  a host.

  It also honours the dedup key the way `c:StatifierRouter.TimerQueue.schedule/2`
  obliges a queue to: an entry whose `key` it already holds is answered
  `:ok` and adds no row, and entries with different keys under one
  `{scope, send_id}` are kept side by side, oldest first. Test-only support
  code, not part of the package's public API.
  """

  @behaviour StatifierRouter.TimerQueue

  @rows_key {__MODULE__, :rows}

  @doc "Every scheduled entry in the calling process, oldest first."
  @spec entries() :: [StatifierRouter.TimerQueue.entry()]
  def entries, do: rows() |> Map.values() |> List.flatten()

  @doc "The entries stored under `{scope, send_id}` in the calling process."
  @spec entries(String.t(), String.t() | nil) :: [StatifierRouter.TimerQueue.entry()]
  def entries(scope, send_id), do: Map.get(rows(), {scope, send_id}, [])

  @impl StatifierRouter.TimerQueue
  def schedule(_queue_config, entry) do
    if Enum.any?(entries(), &(&1.key == entry.key)) do
      :ok
    else
      key = {entry.scope, entry.send_id}
      Process.put(@rows_key, Map.update(rows(), key, [entry], &(&1 ++ [entry])))
      :ok
    end
  end

  @impl StatifierRouter.TimerQueue
  def cancel(_queue_config, scope, send_id) do
    {deleted, kept} = Map.pop(rows(), {scope, send_id}, [])
    Process.put(@rows_key, kept)
    {:ok, length(deleted)}
  end

  defp rows, do: Process.get(@rows_key, %{})
end
