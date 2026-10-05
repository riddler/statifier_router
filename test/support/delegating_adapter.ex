defmodule StatifierRouter.DelegatingAdapter do
  @moduledoc """
  Builds an Ecto adapter module that is not a stock one: every function
  the stock adapter it names exports is defined here and hands its
  arguments to that adapter, and it declares the same behaviours. A repo
  built on it starts the stock adapter's connection, so it speaks that
  adapter's dialect under a module name of its own, the way a host's
  wrapper around a stock adapter does. Test-only support code, not part
  of the package's public API.

      use StatifierRouter.DelegatingAdapter,
        adapter: Ecto.Adapters.SQLite3,
        driver: :exqlite

  `:driver` is the one the stock adapter passes to `Ecto.Adapters.SQL`,
  which the repo's compile step asks for.
  """

  alias Ecto.Adapters.SQL

  defmacro __using__(opts) do
    quote bind_quoted: [target: opts[:adapter], driver: opts[:driver]] do
      @delegating_driver driver

      for {:behaviour, behaviours} <- target.__info__(:attributes),
          behaviour <- behaviours do
        @behaviour behaviour
      end

      for {name, arity} <- target.__info__(:functions) do
        args = Macro.generate_arguments(arity, __MODULE__)

        def unquote(name)(unquote_splicing(args)),
          do: unquote(target).unquote(name)(unquote_splicing(args))
      end

      defmacro __before_compile__(env),
        do: SQL.__before_compile__(@delegating_driver, env)
    end
  end
end

defmodule StatifierRouter.WrappedSQLite3 do
  @moduledoc """
  An adapter module that is not `Ecto.Adapters.SQLite3` but hands every
  callback to it (`StatifierRouter.DelegatingAdapter`). Test-only support
  code.
  """

  use StatifierRouter.DelegatingAdapter, adapter: Ecto.Adapters.SQLite3, driver: :exqlite
end

defmodule StatifierRouter.WrappedPostgres do
  @moduledoc """
  An adapter module that is not `Ecto.Adapters.Postgres` but hands every
  callback to it (`StatifierRouter.DelegatingAdapter`). Test-only support
  code.
  """

  use StatifierRouter.DelegatingAdapter, adapter: Ecto.Adapters.Postgres, driver: :postgrex
end

defmodule StatifierRouter.WrappedSQLiteRepo do
  @moduledoc """
  An Ecto repo on SQLite through `StatifierRouter.WrappedSQLite3`, an
  adapter module that is not the stock one. Like
  `StatifierRouter.SQLiteRepo` it has no config of its own: each test
  starts it with the database file it migrates. Test-only support code.
  """

  use Ecto.Repo,
    otp_app: :statifier_router,
    adapter: StatifierRouter.WrappedSQLite3
end

defmodule StatifierRouter.WrappedPostgresRepo do
  @moduledoc """
  An Ecto repo on Postgres through `StatifierRouter.WrappedPostgres`, an
  adapter module that is not the stock one. It has no config of its own:
  each test starts it with `StatifierRouter.TestRepo`'s connection
  options. Test-only support code.
  """

  use Ecto.Repo,
    otp_app: :statifier_router,
    adapter: StatifierRouter.WrappedPostgres
end
