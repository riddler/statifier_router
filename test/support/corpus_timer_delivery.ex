defmodule StatifierRouter.CorpusTimerDelivery do
  @moduledoc """
  The `StatifierOban.Timer.Delivery` the corpus's Oban run mode fires its
  timers through, written as a process-less host writes one. The scope a
  timer was scheduled under is its execution's id. An active execution
  takes the event `StatifierOban.Timer.Delivery.fired_event/2` builds as
  one more step; one that is no longer active discards it, answering the
  store's own word for its status.

  The step runs on the configuration of the case running in this process,
  `StatifierRouter.CorpusRunner.current_config/0`: the runner drains the
  timers queue in its own process, so the job is fired there. Test-only
  support code, not part of the package's public API.
  """

  @behaviour StatifierOban.Timer.Delivery

  alias StatifierOban.Timer.Delivery
  alias StatifierPersistence.Storage
  alias StatifierRouter.CorpusRunner

  @impl Delivery
  def deliver(execution_id, effect) do
    config = CorpusRunner.current_config()
    {:ok, record} = Storage.fetch_execution(config.store, execution_id)
    event = Delivery.fired_event(execution_id, effect)

    case CorpusRunner.step_fired(config, execution_id, record.content_hash, event) do
      {:ok, _execution} -> :delivered
      {:discarded, execution} -> {:discarded, execution.status}
    end
  end
end
