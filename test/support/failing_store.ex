defmodule StatifierRouter.FailingStore do
  @moduledoc """
  This suite's Ecto storage adapter in every respect but one:
  `fetch_execution/2` refuses with `{:error, {:adapter, :unreachable}}`,
  the arm `StatifierPersistence.Storage.Adapter`'s error type carries a
  backend failure in.

  It exists so a test can pin
  `StatifierRouter.Addresses.reap/2`'s rule that a status read which fails
  for any reason but a missing execution ends the call before it writes
  anything. `:execution_not_found` no longer takes that path - it deletes
  the row - so an orphaned row can no longer stand in for a failed read.

  A test uses it by replacing the adapter of a store built the ordinary
  way (`%StatifierPersistence.Storage{store | adapter: __MODULE__}`), so
  the opts it hands every delegated callback are the ones
  `StatifierPersistence.Storage.Ecto.init/1` resolved. Test-only support
  code, not part of the package's public API.
  """

  @behaviour StatifierPersistence.Storage.Adapter

  alias StatifierPersistence.Storage.Ecto, as: EctoStorage

  @impl StatifierPersistence.Storage.Adapter
  def fetch_execution(_opts, _execution_id), do: {:error, {:adapter, :unreachable}}

  @impl StatifierPersistence.Storage.Adapter
  defdelegate init(opts), to: EctoStorage

  @impl StatifierPersistence.Storage.Adapter
  defdelegate save_chart(opts, chart_record), to: EctoStorage

  @impl StatifierPersistence.Storage.Adapter
  defdelegate fetch_chart(opts, content_hash), to: EctoStorage

  @impl StatifierPersistence.Storage.Adapter
  defdelegate save_position(opts, position_record), to: EctoStorage

  @impl StatifierPersistence.Storage.Adapter
  defdelegate fetch_position(opts, session_id), to: EctoStorage

  @impl StatifierPersistence.Storage.Adapter
  defdelegate insert_execution(opts, execution_record), to: EctoStorage

  @impl StatifierPersistence.Storage.Adapter
  defdelegate update_execution(opts, execution_record), to: EctoStorage
end
