defmodule StatifierRouter.Migrations do
  @moduledoc """
  Versioned migrations for this package's tables, in the shape
  statifier_persistence's `StatifierPersistence.Ecto.Migrations` uses: the
  host writes one ordinary migration that delegates here, and later
  package versions ship higher-numbered migration modules the same call
  picks up.

      defmodule MyApp.Repo.Migrations.AddStatifierRouter do
        use Ecto.Migration

        def up, do: StatifierRouter.Migrations.up(prefix: "routing")
        def down, do: StatifierRouter.Migrations.down(prefix: "routing")
      end

  The options are the two storage options of `StatifierRouter.Config`,
  `:table_prefix` and `:prefix`, resolved the same way, `:from` and
  `:version`, the three layout options statifier_persistence's
  migrations helper takes, under the same spellings, and `:primary_key`:

    * `:table_prefix` - a string prefixed to every table name, default
      `"statifier_router_"`. Pass the same value the host's
      `StatifierRouter.Config` carries.
    * `:prefix` - the Postgres schema the tables live in, default `nil`.
      When it is set, `up/1` creates the schema if it does not exist and
      `down/1` leaves it in place: dropping a schema the host may share is
      not this package's call.
    * `:from` and `:version` - where a call starts and where it ends, in
      both directions. `up/1` migrates from `from:` (default: V01) up
      through `version:` (default: the newest this package knows), and
      `down/1` rolls back from `from:` (default: the newest) down through
      `version:` (default: V01, that is, everything).
    * `:leading_columns` - host-owned columns placed immediately after
      `id` in every table a version creates, in the order given, default
      `[]`. A keyword list of `name: {type, opts}`, where `type` and `opts`
      are what `Ecto.Migration.add/3` takes:
      `leading_columns: [branch_id: {:text, null: true}]` puts a nullable
      `branch_id` at ordinal position 2 on all four tables. The package's
      schemas do not declare the column, so the package never reads or
      writes it; a default or a `NOT NULL` belongs to a later migration of
      the host's own. A name a table the call creates already declares -
      any column `StatifierRouter.Migrations.V01` or
      `StatifierRouter.Migrations.V02` lists for it - raises
      `ArgumentError` naming the column and those tables, before any DDL
      runs, where Postgres would otherwise refuse the `CREATE TABLE` with a
      duplicate column. A name only a table the call does not create
      declares is a host column like any other: `up(from: 2)` may lead
      with `expires_at`, which only V01's dedupe table has. Without
      `:primary_key`, the primary key is the repo's
      `:migration_primary_key` and is not checked: a repo that sets it to
      `false` may lead with an `id` of its own. With `:primary_key` set,
      the package declares `id` itself, and a leading `id` raises like any
      other package column.
    * `:timestamps_position` - where `inserted_at` goes in every table a
      version creates that has one (the address table, the routing ledger
      and the subscription table; the dedupe table has none): `:trailing`
      (default: the layout `StatifierRouter.Migrations.V01` and
      `StatifierRouter.Migrations.V02` document) or `:leading`
      (immediately after `id` and the `:leading_columns`). The address
      table's `terminal_seen_at` is not a timestamp column in this sense
      and stays where it is.
    * `:column_collations` - a collation per package text column, applied
      wherever a version declares that column in a `CREATE TABLE`, default
      `[]` (every column takes the database default). A keyword list of
      `name: collation`, the collation a non-empty string:
      `column_collations: [execution_id: "C"]` declares `execution_id`
      `COLLATE "C"` on the address table, the routing ledger and the
      subscription table. The names are the text columns the versions
      declare - `scope`, `document`, `key`, `execution_id`, `binding_id`,
      `message_id`, `outcome`, `reason` and `invoke_id` - and the
      collation must be one the database knows; a host column takes its
      collation in its own `:leading_columns` opts instead.
    * `:primary_key` - the type and default of the `id` primary key of
      every table a version creates, in place of the repo's
      `:migration_primary_key`, default: not set. A keyword list with a
      `:type`, required, and a `:default`, optional, each what
      `Ecto.Migration.add/3` takes: `primary_key: [type: :text, default:
      fragment("gen_random_uuid()::text")]` builds `id` as a text primary
      key the database fills in, on all four tables. The column is always
      named `id`, the name the schemas in `StatifierRouter.Schema` read.
      The package inserts no id of its own, so the column needs a default
      the database fills in (a `bigserial` or an identity column has one
      already); a key without one fails every insert the package makes.
      The schemas read the id back as the database holds it, an integer or
      a string (`StatifierRouter.Schema.Id`), and
      `StatifierRouter.Addresses.reap/2` sweeps in the id column's own
      order. Left out, every table takes the repo's primary key, exactly as
      before the option existed.

  The three layout options and `:primary_key` apply to a fresh create
  only. Each table is laid out by the version that creates it - V01 the
  address table, the dedupe table and the routing ledger, V02 the
  subscription table - and no version re-places a column or re-types a
  key in a table that already exists, so adding an option later changes
  nothing in the tables already built: a host that ran V01 under the
  repo's key and sets `:primary_key` for V02 gets the new key on the
  subscription table alone, and each table keeps the key it was built
  with. Left out, every version builds exactly the tables it built before
  the options existed. `down/1` accepts them too, so one options list
  serves both directions, and ignores them.

  A host already running an older version writes its next migration with
  `from:` set to the first version it has not run, rather than re-running
  V01's `CREATE TABLE` against tables that already exist. A host whose
  first migration is capped with `version: N` caps its rollback to match
  with `from: N`.

  A fault in the options raises `ArgumentError`: a migration has no caller
  to hand an `{:error, reason}` to.

  `StatifierRouter.Migrations.V01` records what the first version creates,
  `StatifierRouter.Migrations.V02` what the second adds, and
  `StatifierRouter.Migrations.V03` what the third renames.

  `:from` is **inclusive**: `up(from: 2)` runs V02, and a host already on
  V01 that writes it gets the subscription table without V01's
  `CREATE TABLE` running a second time (ADR-0007, section 6).

  ## Upgrading to V03

  V03 renames the subscription table's unique index, which V02 named past
  the 63 bytes Postgres keeps of an identifier, to `<table>_invocation_index`.
  A host that has already run V02 runs one more version, in a new migration
  of its own:

      def up, do: StatifierRouter.Migrations.up(from: 3)
      def down, do: StatifierRouter.Migrations.down(from: 3, version: 3)

  with the same `:table_prefix` and `:prefix` as its earlier migrations.
  V03 renames the index in place and nothing is rebuilt. A host whose first
  migration calls `up/1` with no `version:` gets V03 from it on a fresh
  database, and still writes the migration above for the databases that
  ran the first one before V03 existed: on a fresh database the second
  run finds the index already renamed and does nothing.

  ## Index names and a long `:table_prefix`

  Every index name the versions leave is the table's name followed by a
  suffix, and Postgres keeps at most 63 bytes of it. Under the default
  prefix, `"statifier_router_"` (17 bytes), every name fits; the longest,
  `statifier_router_routing_ledger_binding_id_inserted_at_index`, is 60
  bytes. A `:table_prefix` longer than 20 bytes takes that name past 63,
  and longer ones take more of the names with it. Such a prefix is
  accepted: Postgres creates the index under its first 63 bytes and logs a
  notice, and the index works as before, since the package's queries name
  an index's columns, never its name. What changes is the name a host
  reads back - a unique violation's constraint name, or `pg_indexes` -
  which is the truncated one. V03 accounts for that when it renames: it
  looks the index up under the name Postgres gave it. A prefix of 49 bytes
  or more fails V01 itself: the routing ledger's table name then takes up
  all 63 bytes, its index name cut to 63 bytes is the table's own name,
  and Postgres refuses the `CREATE INDEX` because that relation exists.
  """

  alias StatifierRouter.Config

  @initial_version 1

  @timestamps_positions [:trailing, :leading]

  # The text columns the versions declare in a `CREATE TABLE`, which
  # `:column_collations` may name.
  @collatable_columns [
    :scope,
    :document,
    :key,
    :execution_id,
    :binding_id,
    :message_id,
    :outcome,
    :reason,
    :invoke_id
  ]

  # The columns each version declares in each table it creates. A leading
  # column may not reuse one of them in a table the call creates: Postgres
  # refuses a duplicate column name. The primary key is left out: whether
  # a table gets one, and its name, is the repo's :migration_primary_key,
  # which Ecto reads inside the migration runner, and a repo that turns it
  # off may lead with an `id` of its own. Under :primary_key the package
  # declares `id` itself, and up/1 adds it to every set.
  @package_columns %{
    1 => [
      addresses: [:scope, :document, :key, :execution_id, :inserted_at, :terminal_seen_at],
      dedupe: [:binding_id, :message_id, :expires_at],
      routing_ledger: [
        :binding_id,
        :message_id,
        :scope,
        :outcome,
        :key,
        :execution_id,
        :reason,
        :inserted_at
      ]
    ],
    2 => [
      subscriptions: [:binding_id, :execution_id, :invoke_id, :scope, :key, :inserted_at]
    ],
    3 => []
  }

  @migrations %{
    1 => StatifierRouter.Migrations.V01,
    2 => StatifierRouter.Migrations.V02,
    3 => StatifierRouter.Migrations.V03
  }

  # Read off the map rather than written beside it, so the default target
  # cannot name a version this module does not reach.
  @current_version @migrations |> Map.keys() |> Enum.max()

  @doc """
  Migrates the tables from `from:` (default: V01) up through `version:`
  (default: the newest).
  """
  @spec up(keyword()) :: :ok
  def up(opts \\ []) when is_list(opts) do
    {from, opts} = Keyword.pop(opts, :from, @initial_version)
    validate_version!(from, "from")
    {storage, target} = parse!(opts, @current_version)
    span = span!(from, target, :up)
    refuse_package_column_names!(storage.leading_columns, span, storage.primary_key)

    Enum.each(span, fn version -> Map.fetch!(@migrations, version).up(storage) end)
  end

  @doc """
  Rolls the tables back from `from:` (default: the newest version this
  package knows) down through `version:` (default: V01, that is,
  everything).
  """
  @spec down(keyword()) :: :ok
  def down(opts \\ []) when is_list(opts) do
    {from, opts} = Keyword.pop(opts, :from, @current_version)
    validate_version!(from, "from")
    {storage, target} = parse!(opts, @initial_version)

    from
    |> span!(target, :down)
    |> Enum.each(fn version -> Map.fetch!(@migrations, version).down(storage) end)
  end

  # The versions a call walks, in the order it walks them. A span that runs
  # the wrong way for its direction is a fault in the host's options.
  defp span!(from, target, :up) when from <= target, do: from..target//1
  defp span!(from, target, :down) when from >= target, do: from..target//-1

  defp span!(from, target, :up) do
    raise ArgumentError, "from: #{from} is above version: #{target}; up/1 does not roll back"
  end

  defp span!(from, target, :down) do
    raise ArgumentError, "from: #{from} is below version: #{target}; down/1 does not migrate up"
  end

  defp parse!(opts, default_version) do
    {version, opts} = Keyword.pop(opts, :version, default_version)
    validate_version!(version, "version")
    {layout, opts} = layout!(opts)

    with :ok <- Config.reject_unknown(opts, Config.storage_keys()),
         {:ok, storage} <- Config.storage(opts) do
      {storage |> Map.new() |> Map.merge(layout), version}
    else
      {:error, reason} ->
        raise ArgumentError, "invalid migration options: #{inspect(reason)}"
    end
  end

  # The three layout options, validated with statifier_persistence's rules
  # and popped before the storage options are checked: they are options of
  # the migration, never keys of `StatifierRouter.Config`.
  defp layout!(opts) do
    {leading_columns, opts} = Keyword.pop(opts, :leading_columns, [])
    {timestamps_position, opts} = Keyword.pop(opts, :timestamps_position, :trailing)
    {column_collations, opts} = Keyword.pop(opts, :column_collations, [])
    {primary_key, opts} = pop_primary_key(opts)

    layout = %{
      leading_columns: validate_leading_columns!(leading_columns),
      timestamps_position: validate_timestamps_position!(timestamps_position),
      column_collations: validate_column_collations!(column_collations),
      primary_key: primary_key
    }

    {layout, opts}
  end

  defp validate_leading_columns!(columns) when is_list(columns) do
    if not Keyword.keyword?(columns) do
      raise ArgumentError,
            "the :leading_columns option must be a keyword list of name: {type, opts}, " <>
              "got: #{inspect(columns)}"
    end

    Enum.each(columns, &validate_leading_column!/1)

    case Keyword.keys(columns) -- Enum.uniq(Keyword.keys(columns)) do
      [] ->
        columns

      duplicated ->
        raise ArgumentError,
              "the :leading_columns option names #{inspect(Enum.uniq(duplicated))} " <>
                "more than once"
    end
  end

  defp validate_leading_columns!(other) do
    raise ArgumentError,
          "the :leading_columns option must be a keyword list of name: {type, opts}, " <>
            "got: #{inspect(other)}"
  end

  defp validate_leading_column!({name, {_type, opts}}) when is_list(opts) do
    if not Keyword.keyword?(opts) do
      raise ArgumentError,
            "the :leading_columns opts for #{inspect(name)} must be a keyword list, " <>
              "got: #{inspect(opts)}"
    end
  end

  defp validate_leading_column!({name, other}) do
    raise ArgumentError,
          "the :leading_columns entry for #{inspect(name)} must be {type, opts}, " <>
            "got: #{inspect(other)}"
  end

  # Checked in up/1 only, against the tables the span creates: down/1
  # creates no table and ignores the layout options, and a name only a
  # table outside the span declares is a host column like any other.
  defp refuse_package_column_names!(leading_columns, span, primary_key) do
    tables = package_columns(span, primary_key)

    collisions =
      for {name, _column} <- leading_columns,
          declared_in = for({table, columns} <- tables, name in columns, do: table),
          declared_in != [],
          do: "#{inspect(name)} (in #{Enum.join(declared_in, ", ")})"

    if collisions != [] do
      raise ArgumentError,
            "the :leading_columns option names a column the package declares: " <>
              Enum.join(collisions, "; ") <>
              "; a host column needs a name no table this call creates declares"
    end

    :ok
  end

  # The columns the refusal consults: each table the span creates, in the
  # span's order, with the names @package_columns declares for it, and
  # `id` first when the call sets :primary_key. Public only so the host
  # columns test can compare the whole name set with the catalog's.
  @doc false
  @spec package_columns(Enumerable.t(), term()) :: [{atom(), [atom()]}]
  def package_columns(span, primary_key) do
    for {table, columns} <- Enum.flat_map(span, &Map.fetch!(@package_columns, &1)),
        do: {table, if(primary_key, do: [:id | columns], else: columns)}
  end

  # The primary key option, validated and popped with the layout options.
  # Left out it is nil, and every version calls table/2 exactly as it did
  # before the option existed.
  defp pop_primary_key(opts) do
    case Keyword.pop(opts, :primary_key) do
      {nil, opts} -> {nil, opts}
      {primary_key, opts} -> {validate_primary_key!(primary_key), opts}
    end
  end

  defp validate_primary_key!(primary_key) when is_list(primary_key) and primary_key != [] do
    if not Keyword.keyword?(primary_key) do
      raise ArgumentError,
            "the :primary_key option must be a keyword list of type: and default:, " <>
              "got: #{inspect(primary_key)}"
    end

    case Enum.reject(Keyword.keys(primary_key), &(&1 in [:type, :default])) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "the :primary_key option takes only :type and :default, got: #{inspect(unknown)}"
    end

    if Keyword.keys(primary_key) != Enum.uniq(Keyword.keys(primary_key)) do
      raise ArgumentError,
            "the :primary_key option names a key more than once: #{inspect(primary_key)}"
    end

    if not Keyword.has_key?(primary_key, :type) do
      raise ArgumentError,
            "the :primary_key option needs a :type, got: #{inspect(primary_key)}"
    end

    primary_key
  end

  defp validate_primary_key!(other) do
    raise ArgumentError,
          "the :primary_key option must be a keyword list of type: and default:, " <>
            "got: #{inspect(other)}"
  end

  defp validate_timestamps_position!(position) when position in @timestamps_positions,
    do: position

  defp validate_timestamps_position!(other) do
    raise ArgumentError,
          "the :timestamps_position option must be one of " <>
            "#{inspect(@timestamps_positions)}, got: #{inspect(other)}"
  end

  defp validate_column_collations!(collations) when is_list(collations) do
    if not Keyword.keyword?(collations) do
      raise ArgumentError,
            "the :column_collations option must be a keyword list of name: collation, " <>
              "got: #{inspect(collations)}"
    end

    Enum.each(collations, &validate_column_collation!/1)

    case Keyword.keys(collations) -- Enum.uniq(Keyword.keys(collations)) do
      [] ->
        collations

      duplicated ->
        raise ArgumentError,
              "the :column_collations option names #{inspect(Enum.uniq(duplicated))} " <>
                "more than once"
    end
  end

  defp validate_column_collations!(other) do
    raise ArgumentError,
          "the :column_collations option must be a keyword list of name: collation, " <>
            "got: #{inspect(other)}"
  end

  defp validate_column_collation!({name, collation})
       when name in @collatable_columns and is_binary(collation) and collation != "",
       do: :ok

  defp validate_column_collation!({name, collation}) when name in @collatable_columns do
    raise ArgumentError,
          "the :column_collations entry for #{inspect(name)} must be a non-empty string, " <>
            "got: #{inspect(collation)}"
  end

  defp validate_column_collation!({name, _collation}) do
    raise ArgumentError,
          "unknown column #{inspect(name)} in :column_collations; " <>
            "known columns are #{inspect(@collatable_columns)}"
  end

  defp validate_version!(version, name) do
    if not (is_integer(version) and version in @initial_version..@current_version) do
      raise ArgumentError,
            "unknown migration #{name} #{inspect(version)}; " <>
              "this package knows versions #{@initial_version} through #{@current_version}"
    end

    :ok
  end
end
