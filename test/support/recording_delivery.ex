defmodule StatifierRouter.RecordingDelivery do
  @moduledoc """
  A delivery module for this package's own tests: it records every call it
  receives and answers from a script, writing nothing.

  `StatifierRouter.route/3` calls the delivery module in the process that
  routes the event, so the recording is a message sent to that same
  process, `{:deliver, binding_id, key, delivery}`, and the script is read
  from that process's dictionary: `answer/2` sets what the module answers
  for one binding, as a term or as a zero-arity function whose result is
  the answer. A binding without a scripted answer is answered
  `{:delivered, binding_id, "ex_9k2q"}`. Test-only support code, not part
  of the package's public API.
  """

  @doc "Scripts the answer for the binding `binding_id` in the calling process."
  @spec answer(String.t(), term() | (-> term())) :: :ok
  def answer(binding_id, answer) do
    Process.put({__MODULE__, binding_id}, answer)
    :ok
  end

  @doc false
  def deliver(_config, %StatifierRouter.Binding{id: id}, key, delivery) do
    send(self(), {:deliver, id, key, delivery})

    case Process.get({__MODULE__, id}, {:delivered, id, "ex_9k2q"}) do
      fun when is_function(fun, 0) -> fun.()
      answer -> answer
    end
  end
end
