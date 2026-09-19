defmodule StatifierRouter.TestPersistence do
  @moduledoc """
  statifier_persistence's Ecto configuration over this suite's own repo,
  so the executions a delivery creates and steps are written through the
  delivery's transaction (statifier_persistence's README, "Writing inside
  a caller's transaction"). Its tables are created by
  `StatifierRouter.BootstrapMigrations`. Test-only support code.
  """

  use StatifierPersistence.Ecto, repo: StatifierRouter.TestRepo
end
