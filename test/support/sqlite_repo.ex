defmodule StatifierRouter.SQLiteRepo do
  @moduledoc """
  An Ecto repo on SQLite, for the tests that run the package's migration
  versions against an adapter other than Postgres. It has no config of its
  own: each test starts it with the database file it migrates. Test-only
  support code, not part of the package's public API.
  """

  use Ecto.Repo,
    otp_app: :statifier_router,
    adapter: Ecto.Adapters.SQLite3
end
