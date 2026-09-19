defmodule StatifierRouter.TestRepo do
  @moduledoc """
  The Ecto repo backing this package's own test suite.

  Database-backed tests run against a real Postgres server rather than a fake
  or an embedded stand-in, isolated per test through
  `Ecto.Adapters.SQL.Sandbox` - the harness statifier_persistence records in
  its sp-ADR-0005. This module is test-only support code, not part of the
  package's public API.
  """

  use Ecto.Repo,
    otp_app: :statifier_router,
    adapter: Ecto.Adapters.Postgres
end
