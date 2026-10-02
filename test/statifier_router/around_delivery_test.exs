defmodule StatifierRouter.AroundDeliveryTest do
  # Not async, for two reasons. The Broadway processors and the producer's
  # dispatcher are processes of their own, so the SQL sandbox runs in
  # shared mode, owned by the test process, as StatifierRouter.BroadwayTest
  # does. And the statement capture below attaches to every statement the
  # test repo runs, which only a module that runs alone can read as its
  # own.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import StatifierRouter.DeliveryFixtures

  alias Broadway.Message
  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Effect.Send
  alias Statifier.Machine
  alias Statifier.Send.Event, as: SendEvent
  alias StatifierPersistence.Executions
  alias StatifierRouter.BasicHTTP
  alias StatifierRouter.BasicHTTP.Front
  alias StatifierRouter.Binding
  alias StatifierRouter.Config
  alias StatifierRouter.Resolver.Static
  alias StatifierRouter.Schema.Address
  alias StatifierRouter.SendHandler
  alias StatifierRouter.TestRepo
  alias StatifierRouter.Webhook

  # ADR-0003, the Amendment of 2026-10-02: `:around_delivery` is handed
  # `(scope, door, work)` and runs a whole delivery inside it on the doors
  # `:route`, `:partition` and `:basichttp`. The context a test wrapper
  # sets is a process-dictionary entry under this key, holding the scope;
  # a telemetry handler on the test repo's query event reads it in the
  # process that runs each statement, so every statement is captured with
  # the context it ran under.
  @context :around_delivery_test_context

  @now ~U[2026-10-02 08:00:00.000000Z]
  @base_url "https://depot.example/scxml"
  @form "application/x-www-form-urlencoded"
  @type_string "myapp:router"

  # The statements a configuration without the option issues, captured by
  # the test below at the commit before the option existed and normalized
  # by normalize/1: a create through an address row with a location, a
  # BasicHTTP POST, a step that finishes the execution, that step's
  # message again, and a key_refused row.
  @created [
    "begin",
    "SAVEPOINT sr_delivery_N",
    "INSERT INTO \"statifier_router_dedupe\" AS s0 (\"binding_id\",\"expires_at\",\"message_id\") VALUES ($,$,$) ON CONFLICT (\"binding_id\",\"message_id\") DO UPDATE SET \"expires_at\" = $ WHERE (s0.\"expires_at\" < $)",
    "SELECT s0.\"id\", s0.\"scope\", s0.\"document\", s0.\"key\", s0.\"execution_id\", s0.\"terminal_seen_at\", s0.\"inserted_at\" FROM \"statifier_router_addresses\" AS s0 WHERE (((s0.\"scope\" = $) AND (s0.\"document\" = $)) AND (s0.\"key\" = $))",
    "INSERT INTO \"statifier_router_addresses\" (\"document\",\"execution_id\",\"inserted_at\",\"key\",\"scope\") VALUES ($,$,$,$,$) ON CONFLICT (\"scope\",\"document\",\"key\") DO NOTHING RETURNING \"id\"",
    "INSERT INTO \"statifier_router_locations\" (\"address_id\",\"inserted_at\",\"token\") VALUES ($,$,$) RETURNING \"id\"",
    "SELECT s0.\"retired_at\", s0.\"retired_by\" FROM \"statifier_charts\" AS s0 WHERE (s0.\"content_hash\" = $) AND (NOT (s0.\"retired_at\" IS NULL))",
    "SELECT pg_advisory_xact_lock(hashtextextended($::text, 0))",
    "SELECT s0.\"id\" FROM \"statifier_executions\" AS s0 WHERE (s0.\"execution_id\" = $) FOR UPDATE",
    "INSERT INTO \"statifier_executions\" (\"content_hash\",\"execution_id\",\"id\",\"identity_blob\",\"inserted_at\",\"position_blob\",\"status\",\"updated_at\") VALUES ($,$,$,$,$,$,$,$)",
    "SELECT pg_advisory_xact_lock(hashtextextended($::text, 0))",
    "SELECT s0.\"id\" FROM \"statifier_executions\" AS s0 WHERE (s0.\"execution_id\" = $) FOR UPDATE",
    "SELECT s0.\"id\", s0.\"execution_id\", s0.\"status\", s0.\"content_hash\", s0.\"identity_blob\", s0.\"position_blob\", s0.\"failure\", s0.\"session_id\", s0.\"metadata\", s0.\"outcome_blob\", s0.\"ended_at\", s0.\"inserted_at\", s0.\"updated_at\" FROM \"statifier_executions\" AS s0 WHERE (s0.\"execution_id\" = $)",
    "SELECT s0.\"id\", s0.\"execution_id\", s0.\"status\", s0.\"content_hash\", s0.\"identity_blob\", s0.\"position_blob\", s0.\"failure\", s0.\"session_id\", s0.\"metadata\", s0.\"outcome_blob\", s0.\"ended_at\", s0.\"inserted_at\", s0.\"updated_at\" FROM \"statifier_executions\" AS s0 WHERE (s0.\"execution_id\" = $)",
    "SELECT s0.\"seq\", s0.\"input_blob\" FROM \"statifier_inputs\" AS s0 WHERE (s0.\"execution_id\" = $) ORDER BY s0.\"seq\" DESC LIMIT 1",
    "INSERT INTO \"statifier_inputs\" (\"door\",\"execution_id\",\"id\",\"input_blob\",\"inserted_at\",\"seq\",\"updated_at\") VALUES ($,$,$,$,$,$,$)",
    "UPDATE \"statifier_executions\" AS s0 SET \"content_hash\" = $, \"failure\" = $, \"identity_blob\" = $, \"position_blob\" = $, \"status\" = $, \"updated_at\" = $ WHERE (s0.\"execution_id\" = $)",
    "INSERT INTO \"statifier_router_routing_ledger\" (\"binding_id\",\"execution_id\",\"inserted_at\",\"key\",\"message_id\",\"outcome\",\"scope\") VALUES ($,$,$,$,$,$,$) RETURNING \"id\"",
    "RELEASE SAVEPOINT sr_delivery_N",
    "commit"
  ]

  @front [
    "SELECT s0.\"id\", s0.\"scope\", s0.\"document\", s0.\"key\", s0.\"execution_id\", s0.\"terminal_seen_at\", s0.\"inserted_at\" FROM \"statifier_router_addresses\" AS s0 INNER JOIN \"statifier_router_locations\" AS s1 ON s1.\"address_id\" = s0.\"id\" WHERE (s1.\"token\" = $)",
    "begin",
    "SAVEPOINT sr_execution_target_N",
    "INSERT INTO \"statifier_router_dedupe\" AS s0 (\"binding_id\",\"expires_at\",\"message_id\") VALUES ($,$,$) ON CONFLICT (\"binding_id\",\"message_id\") DO UPDATE SET \"expires_at\" = $ WHERE (s0.\"expires_at\" < $)",
    "SELECT s0.\"id\", s0.\"scope\", s0.\"document\", s0.\"key\", s0.\"execution_id\", s0.\"terminal_seen_at\", s0.\"inserted_at\" FROM \"statifier_router_addresses\" AS s0 WHERE (((s0.\"scope\" = $) AND (s0.\"document\" = $)) AND (s0.\"key\" = $))",
    "SELECT s0.\"id\", s0.\"execution_id\", s0.\"status\", s0.\"content_hash\", s0.\"identity_blob\", s0.\"position_blob\", s0.\"failure\", s0.\"session_id\", s0.\"metadata\", s0.\"outcome_blob\", s0.\"ended_at\", s0.\"inserted_at\", s0.\"updated_at\" FROM \"statifier_executions\" AS s0 WHERE (s0.\"execution_id\" = $)",
    "SELECT pg_advisory_xact_lock(hashtextextended($::text, 0))",
    "SELECT s0.\"id\" FROM \"statifier_executions\" AS s0 WHERE (s0.\"execution_id\" = $) FOR UPDATE",
    "SELECT s0.\"id\", s0.\"execution_id\", s0.\"status\", s0.\"content_hash\", s0.\"identity_blob\", s0.\"position_blob\", s0.\"failure\", s0.\"session_id\", s0.\"metadata\", s0.\"outcome_blob\", s0.\"ended_at\", s0.\"inserted_at\", s0.\"updated_at\" FROM \"statifier_executions\" AS s0 WHERE (s0.\"execution_id\" = $)",
    "SELECT s0.\"id\", s0.\"execution_id\", s0.\"status\", s0.\"content_hash\", s0.\"identity_blob\", s0.\"position_blob\", s0.\"failure\", s0.\"session_id\", s0.\"metadata\", s0.\"outcome_blob\", s0.\"ended_at\", s0.\"inserted_at\", s0.\"updated_at\" FROM \"statifier_executions\" AS s0 WHERE (s0.\"execution_id\" = $)",
    "SELECT s0.\"seq\", s0.\"input_blob\" FROM \"statifier_inputs\" AS s0 WHERE (s0.\"execution_id\" = $) ORDER BY s0.\"seq\" DESC LIMIT 1",
    "INSERT INTO \"statifier_inputs\" (\"door\",\"execution_id\",\"id\",\"input_blob\",\"inserted_at\",\"seq\",\"updated_at\") VALUES ($,$,$,$,$,$,$)",
    "UPDATE \"statifier_executions\" AS s0 SET \"content_hash\" = $, \"failure\" = $, \"identity_blob\" = $, \"position_blob\" = $, \"status\" = $, \"updated_at\" = $ WHERE (s0.\"execution_id\" = $)",
    "INSERT INTO \"statifier_router_routing_ledger\" (\"binding_id\",\"execution_id\",\"inserted_at\",\"key\",\"message_id\",\"outcome\",\"scope\") VALUES ($,$,$,$,$,$,$) RETURNING \"id\"",
    "RELEASE SAVEPOINT sr_execution_target_N",
    "commit"
  ]

  @delivered [
    "begin",
    "SAVEPOINT sr_delivery_N",
    "INSERT INTO \"statifier_router_dedupe\" AS s0 (\"binding_id\",\"expires_at\",\"message_id\") VALUES ($,$,$) ON CONFLICT (\"binding_id\",\"message_id\") DO UPDATE SET \"expires_at\" = $ WHERE (s0.\"expires_at\" < $)",
    "SELECT s0.\"id\", s0.\"scope\", s0.\"document\", s0.\"key\", s0.\"execution_id\", s0.\"terminal_seen_at\", s0.\"inserted_at\" FROM \"statifier_router_addresses\" AS s0 WHERE (((s0.\"scope\" = $) AND (s0.\"document\" = $)) AND (s0.\"key\" = $))",
    "SELECT s0.\"id\", s0.\"execution_id\", s0.\"status\", s0.\"content_hash\", s0.\"identity_blob\", s0.\"position_blob\", s0.\"failure\", s0.\"session_id\", s0.\"metadata\", s0.\"outcome_blob\", s0.\"ended_at\", s0.\"inserted_at\", s0.\"updated_at\" FROM \"statifier_executions\" AS s0 WHERE (s0.\"execution_id\" = $)",
    "SELECT pg_advisory_xact_lock(hashtextextended($::text, 0))",
    "SELECT s0.\"id\" FROM \"statifier_executions\" AS s0 WHERE (s0.\"execution_id\" = $) FOR UPDATE",
    "SELECT s0.\"id\", s0.\"execution_id\", s0.\"status\", s0.\"content_hash\", s0.\"identity_blob\", s0.\"position_blob\", s0.\"failure\", s0.\"session_id\", s0.\"metadata\", s0.\"outcome_blob\", s0.\"ended_at\", s0.\"inserted_at\", s0.\"updated_at\" FROM \"statifier_executions\" AS s0 WHERE (s0.\"execution_id\" = $)",
    "SELECT s0.\"id\", s0.\"execution_id\", s0.\"status\", s0.\"content_hash\", s0.\"identity_blob\", s0.\"position_blob\", s0.\"failure\", s0.\"session_id\", s0.\"metadata\", s0.\"outcome_blob\", s0.\"ended_at\", s0.\"inserted_at\", s0.\"updated_at\" FROM \"statifier_executions\" AS s0 WHERE (s0.\"execution_id\" = $)",
    "SELECT s0.\"seq\", s0.\"input_blob\" FROM \"statifier_inputs\" AS s0 WHERE (s0.\"execution_id\" = $) ORDER BY s0.\"seq\" DESC LIMIT 1",
    "INSERT INTO \"statifier_inputs\" (\"door\",\"execution_id\",\"id\",\"input_blob\",\"inserted_at\",\"seq\",\"updated_at\") VALUES ($,$,$,$,$,$,$)",
    "UPDATE \"statifier_executions\" AS s0 SET \"content_hash\" = $, \"ended_at\" = coalesce(s0.\"ended_at\", $::timestamp), \"failure\" = $, \"identity_blob\" = $, \"position_blob\" = $, \"status\" = $, \"updated_at\" = $ WHERE (s0.\"execution_id\" = $)",
    "INSERT INTO \"statifier_router_routing_ledger\" (\"binding_id\",\"execution_id\",\"inserted_at\",\"key\",\"message_id\",\"outcome\",\"scope\") VALUES ($,$,$,$,$,$,$) RETURNING \"id\"",
    "RELEASE SAVEPOINT sr_delivery_N",
    "commit"
  ]

  @duplicate [
    "begin",
    "SAVEPOINT sr_delivery_N",
    "INSERT INTO \"statifier_router_dedupe\" AS s0 (\"binding_id\",\"expires_at\",\"message_id\") VALUES ($,$,$) ON CONFLICT (\"binding_id\",\"message_id\") DO UPDATE SET \"expires_at\" = $ WHERE (s0.\"expires_at\" < $)",
    "INSERT INTO \"statifier_router_routing_ledger\" (\"binding_id\",\"inserted_at\",\"key\",\"message_id\",\"outcome\",\"scope\") VALUES ($,$,$,$,$,$) RETURNING \"id\"",
    "RELEASE SAVEPOINT sr_delivery_N",
    "commit"
  ]

  @key_refused [
    "INSERT INTO \"statifier_router_routing_ledger\" (\"binding_id\",\"inserted_at\",\"message_id\",\"outcome\",\"reason\",\"scope\") VALUES ($,$,$,$,$,$) RETURNING \"id\""
  ]

  # A parcel loaded onto the van tells the depot's tally that it left: an
  # execution-to-execution send from the step the `loaded` scan drives.
  @dispatching """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="at_depot">
    <state id="at_depot">
      <transition event="loaded" target="on_van"/>
    </state>
    <state id="on_van">
      <onentry>
        <send type="myapp:router" target="execution" event="parcel.loaded">
          <param name="document" expr="'depot_tally'"/>
          <param name="key" expr="'depot_9'"/>
        </send>
      </onentry>
      <transition event="delivered" target="doorstep"/>
    </state>
    <final id="doorstep"/>
  </scxml>
  """

  # The depot's tally counts every parcel that leaves it and stays active.
  @tally """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="counting">
    <state id="counting">
      <transition event="parcel.loaded" target="counting"/>
    </state>
  </scxml>
  """

  # Every statement the test repo ran, as `{pid, context, query}`, sent to
  # the test process by a telemetry handler that runs in the process that
  # ran the statement, normalized by normalize/1.
  setup do
    :ok = Sandbox.checkout(TestRepo)
    Sandbox.mode(TestRepo, {:shared, self()})

    test_pid = self()
    handler = "around-delivery-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:statifier_router, :test_repo, :query],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:statement, self(), Process.get(@context), normalize(metadata.query)})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  # What may differ between two runs of the same statement is taken out,
  # so two runs compare: the unique integer in a savepoint name, the
  # parameter numbers, and the order Ecto lists an INSERT's columns and an
  # UPDATE's assignments in, which follows the order of a map's keys.
  defp normalize(query) do
    query = Regex.replace(~r/(sr_[a-z_]+?)_\d+/, query, "\\1_N")
    query = Regex.replace(~r/\$\d+/, query, "$")

    query =
      Regex.replace(~r/^(INSERT INTO \S+(?: AS \S+)? )\(([^)]*)\)/, query, fn _, head, columns ->
        head <> "(" <> sorted(columns, ",") <> ")"
      end)

    Regex.replace(~r/^(UPDATE .*? SET )(.*?)( WHERE )/, query, fn _, head, set, where ->
      head <> sorted(set, ", ") <> where
    end)
  end

  # Splits on `separator` only where a quoted column name follows it, so a
  # comma inside a function call is left alone.
  defp sorted(list, separator) do
    list
    |> String.split(~r/#{separator}(?=")/)
    |> Enum.sort()
    |> Enum.join(separator)
  end

  # The wrapper every wrapped test uses: it reports each call to `pid`, sets
  # the context from the scope it is handed, calls the work once and
  # answers what it answered.
  defp context_wrapper(pid) do
    fn scope, door, work ->
      send(pid, {:wrapped, self(), scope, door})
      Process.put(@context, scope)

      try do
        work.()
      after
        Process.delete(@context)
      end
    end
  end

  defp statements(acc \\ []) do
    receive do
      {:statement, pid, context, query} -> statements([{pid, context, query} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp wrapped(acc \\ []) do
    receive do
      {:wrapped, pid, scope, door} -> wrapped([{pid, scope, door} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp contexts(statements, pid),
    do: for({^pid, context, _query} <- statements, uniq: true, do: context)

  defp queries(statements, pid), do: for({^pid, _context, query} <- statements, do: query)

  # The bindings resolver of the wrapped tests: it reports the context it
  # was called under, and answers the parcel bindings plus one keyed by the
  # van, which a scan that names no van refuses.
  defp reporting_resolver(pid) do
    fn _scope ->
      send(pid, {:bindings_read, self(), Process.get(@context)})
      Enum.map(parcel_bindings() ++ [by_van()], &(&1 |> Binding.new() |> elem(1)))
    end
  end

  defp by_van do
    %{
      id: "loaded_by_van",
      source: "parcel_scans",
      match: "event.kind == 'loaded'",
      key: "event.van_id",
      document: "held_parcel_route",
      event: "loaded",
      data: ["parcel_id"]
    }
  end

  defp post(token, event) do
    %{
      token: token,
      method: "POST",
      content_type: @form,
      body: "_scxmleventname=" <> event,
      query: nil,
      send_key: nil
    }
  end

  defp token(location), do: String.replace_prefix(location, @base_url <> "/", "")

  # The parcel charts with the dispatching parcel and the depot tally
  # beside them, under the scope `7c1e`, with the router's handler as the
  # executor so a `<send>` to the execution target is delivered from
  # inside the step.
  defp sending_config(opts) do
    machines =
      Map.merge(machines(), %{
        "dispatching_parcel" => compile!(@dispatching),
        "depot_tally" => compile!(@tally)
      })

    {:ok, static} = Static.new(for {d, m} <- machines, into: %{}, do: {{"7c1e", d}, m})
    by_hash = Map.new(Map.values(machines), &{Machine.identity(&1).content_hash, &1})

    config =
      config(
        self(),
        Keyword.merge(
          [
            resolver: static,
            chart_resolver: &Map.fetch(by_hash, &1),
            bindings: parcel_bindings("dispatching_parcel"),
            send_type: @type_string
          ],
          opts
        )
      )

    %{config | executor: &SendHandler.handle_effect(config, &1, &2)}
  end

  defp compile!(source) do
    {:ok, machine} = Statifier.compile(source)
    machine
  end

  defp tally_addresses(config) do
    TestRepo.all(from(a in Config.queryable(config, Address), where: a.document == "depot_tally"))
  end

  describe "the option" do
    # sabotage: new/1 took :around_delivery unchecked in place of
    # hooks(opts, @wrapper) -> the arity-2 fun was accepted, red;
    # restored, green.
    test "takes a module exporting around_delivery/3 or an arity-3 fun, and refuses anything else" do
      assert config(self()).around_delivery == nil

      wrapper = context_wrapper(self())
      assert config(self(), around_delivery: wrapper).around_delivery == wrapper

      for bad <- [fn _scope, _work -> :ok end, "around", Enum] do
        assert {:error, {:invalid_value, :around_delivery, ^bad}} =
                 [repo: TestRepo, delivery: StatifierRouter.RecordingDelivery]
                 |> Keyword.put(:around_delivery, bad)
                 |> Config.new()
      end
    end
  end

  describe "a configuration without the option" do
    # sabotage: around_delivery/4's nil clause ran the work inside
    # config.repo.transaction/1 -> the key_refused row gained a begin and
    # a commit, red; restored, green.
    test "issues the same statements and answers the same as before the option existed" do
      config = config(self(), bindings: parcel_bindings(), basichttp: [base_url: @base_url])
      me = self()

      assert {:ok, [{:created_and_delivered, "loaded_scans", execution_id}, {:no_match, _}]} =
               StatifierRouter.route(config, parcel_scan("parcel_scans/1/0001", "loaded"),
                 now: @now
               )

      assert queries(statements(), me) == @created

      {:ok, location} = BasicHTTP.location(config, execution_id)
      _location_read = statements()

      assert Front.handle(config, post(token(location), "noted"), now: @now) ==
               {:ok, {:delivered, "basichttp", execution_id}}

      assert queries(statements(), me) == @front

      assert StatifierRouter.route(
               config,
               parcel_scan("parcel_scans/1/0002", "delivered"),
               now: @now
             ) ==
               {:ok, [{:no_match, "loaded_scans"}, {:delivered, "delivered_scans", execution_id}]}

      assert queries(statements(), me) == @delivered

      assert StatifierRouter.route(
               config,
               parcel_scan("parcel_scans/1/0002", "delivered"),
               now: @now
             ) == {:ok, [{:no_match, "loaded_scans"}, {:duplicate, "delivered_scans"}]}

      assert queries(statements(), me) == @duplicate

      refused = %{parcel_scan("parcel_scans/1/0003", "loaded") | data: %{"kind" => "loaded"}}

      assert {:ok, [{:key_refused, "loaded_scans", {:key, _}}, {:no_match, "delivered_scans"}]} =
               StatifierRouter.route(config, refused, now: @now)

      assert queries(statements(), me) == @key_refused
      assert wrapped() == []
    end
  end

  describe "the :route door" do
    # sabotage: route/3 called route_event/3 without around_delivery/4 ->
    # no :route call, red; restored, green.
    # sabotage: route_event/3 read the bindings in a task of its own,
    # outside the wrapper's process -> the resolver ran with no context,
    # red; restored, green.
    test "runs the bindings read, a key_refused row and each delivery inside one call, under the event's scope" do
      me = self()

      config =
        config(me,
          bindings_resolver: reporting_resolver(me),
          around_delivery: context_wrapper(me)
        )

      assert {:ok,
              [
                {:created_and_delivered, "loaded_scans", _execution_id},
                {:no_match, "delivered_scans"},
                {:key_refused, "loaded_by_van", {:key, _}}
              ]} =
               StatifierRouter.route(config, parcel_scan("parcel_scans/1/0001", "loaded"),
                 now: @now
               )

      assert wrapped() == [{me, "7c1e", :route}]
      assert_received {:bindings_read, ^me, "7c1e"}

      seen = statements()
      assert contexts(seen, me) == ["7c1e"]

      assert Enum.any?(queries(seen, me), &(&1 =~ "statifier_router_dedupe")),
             "the delivery's claim was captured"

      assert Enum.count(
               queries(seen, me),
               &(&1 =~ ~s(INSERT INTO "statifier_router_routing_ledger"))
             ) ==
               2,
             "the delivery's ledger row and the key_refused row were both captured"
    end

    # sabotage: route/3 called route_event/3 without around_delivery/4 ->
    # Webhook.handle/3 made no :route call, red; restored, green.
    test "wraps StatifierRouter.Webhook.handle/3, which routes through route/3" do
      me = self()

      config =
        config(me, bindings: parcel_bindings(), around_delivery: context_wrapper(me))

      request = %{
        scope: "7c1e",
        source: "parcel_scans",
        raw_body: ~s({"kind":"loaded","parcel_id":"pcl_4821"}),
        data: %{"kind" => "loaded", "parcel_id" => "pcl_4821"},
        provider_id: "scan_0001"
      }

      assert {:ok, [{:created_and_delivered, "loaded_scans", _}, {:no_match, _}]} =
               Webhook.handle(config, request, now: @now)

      assert wrapped() == [{me, "7c1e", :route}]
      seen = statements()
      assert queries(seen, me) != []
      assert contexts(seen, me) == ["7c1e"]
    end

    # sabotage: around_delivery/4 ran the work before calling the wrapper
    # and handed the wrapper its answer -> the steps saw no
    # transaction-local setting, red; restored, green.
    test "a wrapper that runs the work in a transaction of its own commits or rolls back every delivery of the call together" do
      me = self()

      wrapper = fn scope, :route, work ->
        {:error, answer} =
          TestRepo.transaction(fn ->
            TestRepo.query!("SELECT set_config('around.scope', $1, true)", [scope])
            TestRepo.rollback(work.())
          end)

        answer
      end

      step = fn store, execution_id, machine, event, opts ->
        %{rows: [[setting]]} = TestRepo.query!("SELECT current_setting('around.scope', true)")
        send(me, {:step_saw, setting})
        Executions.step(store, execution_id, machine, event, opts)
      end

      both = [hd(parcel_bindings()), %{by_van() | id: "loaded_held", key: "event.parcel_id"}]
      config = config(me, bindings: both, around_delivery: wrapper, on_step: step)

      assert {:ok,
              [
                {:created_and_delivered, "loaded_scans", _},
                {:created_and_delivered, "loaded_held", _}
              ]} =
               StatifierRouter.route(config, parcel_scan("parcel_scans/1/0001", "loaded"),
                 now: @now
               )

      # The transaction-local setting the wrapper made reached each step.
      assert_received {:step_saw, "7c1e"}
      assert_received {:step_saw, "7c1e"}

      assert addresses(config) == []
      assert ledger(config) == []
      assert executions() == 0
    end
  end

  describe "the Broadway handler and its partitioner" do
    # sabotage: StatifierRouter.Broadway's bindings_for/2 read
    # Config.bindings_for/2 outside around_delivery/4 -> no :partition
    # call from the producer, red; restored, green.
    test "wraps the partitioner's bindings read in the producer and each message's route/3 in the processor" do
      me = self()

      config =
        config(me,
          bindings_resolver: reporting_resolver(me),
          around_delivery: context_wrapper(me)
        )

      name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        StatifierRouter.Broadway.start_link(
          name: name,
          producer: {Broadway.DummyProducer, []},
          router: config
        )

      scan = parcel_scan("parcel_scans/1/0001", "loaded")

      ref =
        Broadway.test_message(name, scan.data,
          metadata: Map.take(scan, [:scope, :message_id, :source])
        )

      assert_receive {:ack, ^ref, [%Message{}], []}, 5_000

      calls = wrapped()
      assert [{producer, "7c1e", :partition}] = for({_, _, :partition} = c <- calls, do: c)
      assert [{processor, "7c1e", :route}] = for({_, _, :route} = c <- calls, do: c)
      assert producer != processor

      # The partitioner's read runs in the producer with no transaction
      # open: the context the wrapper set in that process is what it sees.
      assert_received {:bindings_read, ^producer, "7c1e"}
      assert_received {:bindings_read, ^processor, "7c1e"}

      seen = statements()
      assert queries(seen, processor) != []
      assert contexts(seen, processor) == ["7c1e"]

      pipeline = Process.whereis(name)
      monitor = Process.monitor(pipeline)
      Process.exit(pipeline, :normal)
      assert_receive {:DOWN, ^monitor, _, _, _}, 5_000
    end
  end

  describe "the BasicHTTP front" do
    # sabotage: the front's deliver/5 called Delivery.deliver_event/4
    # outside around_delivery/4 -> no :basichttp call, red; restored,
    # green.
    # sabotage: handle/3 resolved the token inside around_delivery/4,
    # handed the token as the scope -> a second wrapper call, red;
    # restored, green.
    test "resolves the token outside the wrapper and delivers inside it, under the row's scope" do
      me = self()

      config =
        config(me,
          bindings: parcel_bindings(),
          basichttp: [base_url: @base_url],
          around_delivery: context_wrapper(me)
        )

      {:ok, [{:created_and_delivered, _, execution_id}, _]} =
        StatifierRouter.route(config, parcel_scan("parcel_scans/1/0001", "loaded"), now: @now)

      {:ok, location} = BasicHTTP.location(config, execution_id)
      _before = {wrapped(), statements()}

      assert Front.handle(config, post(token(location), "noted"), now: @now) ==
               {:ok, {:delivered, "basichttp", execution_id}}

      assert wrapped() == [{me, "7c1e", :basichttp}]

      assert [{^me, nil, lookup} | delivery] = statements()
      assert lookup =~ ~s(INNER JOIN "statifier_router_locations")
      assert Enum.any?(delivery, fn {_, _, q} -> q =~ "SAVEPOINT sr_execution_target_N" end)
      assert contexts(delivery, me) == ["7c1e"]
    end
  end

  describe "the execution-target door is not wrapped" do
    # sabotage: SendHandler's deliver_to/5 delivered inside
    # around_delivery/4 under :route -> a second :route call came from
    # inside the sender's step, red; restored, green.
    test "at the executor seam it runs inside the sender's wrapped step, under the sender's context" do
      me = self()
      config = sending_config(around_delivery: context_wrapper(me))

      assert {:ok, [{:created_and_delivered, "loaded_scans", _sender}, {:no_match, _}]} =
               StatifierRouter.route(config, parcel_scan("parcel_scans/1/0001", "loaded"),
                 now: @now
               )

      # One call, the sender's: the target's delivery made none of its own.
      assert wrapped() == [{me, "7c1e", :route}]
      assert [_tally] = tally_addresses(config)

      target =
        statements()
        |> Enum.drop_while(fn {_, _, q} -> q != "SAVEPOINT sr_execution_target_N" end)
        |> Enum.take_while(fn {_, _, q} -> q != "RELEASE SAVEPOINT sr_execution_target_N" end)

      assert target != []
      assert contexts(target, me) == ["7c1e"]
    end

    # sabotage: SendHandler's deliver_to/5 delivered inside
    # around_delivery/4 under :route -> the wrapper was called on the
    # send-processor shape, red; restored, green.
    test "on the send-processor shape nothing of the router's wraps it" do
      me = self()
      config = sending_config(around_delivery: context_wrapper(me), bindings: parcel_bindings())

      {:ok, [{:created_and_delivered, "loaded_scans", sender}, _]} =
        StatifierRouter.route(config, parcel_scan("parcel_scans/1/0001", "loaded"), now: @now)

      _before = {wrapped(), statements()}

      effect = %Send{
        event: "parcel.loaded",
        target: "execution",
        type: @type_string,
        data: %{"document" => "depot_tally", "key" => "depot_9"},
        send_id: "send_1",
        c_index: 3,
        owner: nil,
        macrostep: 1,
        microstep: 0,
        round: 0,
        ordinal: 1
      }

      on_exit(&SendHandler.delete_config/0)
      event = SendEvent.build(effect, sender)

      assert {:ok, [{:handler, SendHandler, payload}]} =
               SendHandler.deliver(effect, event, %{session_id: sender})

      :ok = SendHandler.put_config(config)
      assert SendHandler.perform(payload, %{session_id: sender}) == :ok

      assert wrapped() == []
      assert [_tally] = tally_addresses(config)

      seen = statements()
      assert Enum.any?(queries(seen, me), &(&1 == "SAVEPOINT sr_execution_target_N"))
      assert contexts(seen, me) == [nil]
    end
  end

  describe "the wrapper's contract" do
    # sabotage: around_delivery/4 answered the wrapper's answer whenever
    # the work had reported once -> the transaction's {:ok, answer} came
    # back as route/3's answer and nothing raised, red; restored, green.
    # sabotage: worked/2 stopped after the first report -> a wrapper that
    # called the work twice was not refused, red; restored, green.
    test "raises when the wrapper answers anything but the work's answer, or calls the work other than once" do
      returned = %{parcel_scan("parcel_scans/1/0009", "returned") | data: %{"kind" => "returned"}}

      for wrapper <- [
            fn _scope, _door, work -> TestRepo.transaction(work) end,
            fn _scope, _door, _work -> {:ok, []} end,
            fn _scope, _door, work ->
              work.()
              work.()
            end
          ] do
        config = config(self(), bindings: parcel_bindings(), around_delivery: wrapper)

        assert_raise ArgumentError,
                     ~r/call the work exactly once and answer what the work answered/,
                     fn ->
                       StatifierRouter.route(config, returned, now: @now)
                     end
      end
    end

    # sabotage: around_delivery/4 called the wrapper outside its try/catch
    # -> the three reports of the wrappers that failed after their work
    # stayed in the mailbox, red; restored, green.
    test "a wrapper that fails after or before its work fails with its own error and leaves no report in the caller's mailbox" do
      returned = %{parcel_scan("parcel_scans/1/0009", "returned") | data: %{"kind" => "returned"}}

      route = fn wrapper ->
        config = config(self(), bindings: parcel_bindings(), around_delivery: wrapper)
        StatifierRouter.route(config, returned, now: @now)
      end

      assert_raise RuntimeError, "the context did not reset", fn ->
        route.(fn _scope, _door, work ->
          work.()
          raise "the context did not reset"
        end)
      end

      assert catch_exit(
               route.(fn _scope, _door, work ->
                 work.()
                 exit(:context_lost)
               end)
             ) == :context_lost

      assert catch_throw(
               route.(fn _scope, _door, work ->
                 work.()
                 throw(:context_lost)
               end)
             ) == :context_lost

      assert_raise RuntimeError, "no context for this scope", fn ->
        route.(fn _scope, _door, _work -> raise "no context for this scope" end)
      end

      {:messages, messages} = Process.info(self(), :messages)
      assert for({ref, _answer} = report when is_reference(ref) <- messages, do: report) == []
    end

    # sabotage: call_wrapper/4's module clause handed around_delivery/3
    # the door and the scope swapped -> the module saw :route as the
    # scope, red; restored, green.
    test "calls a module's around_delivery/3 with the scope, the door and the work" do
      Process.put(:around_delivery_test_pid, self())
      config = config(self(), bindings: parcel_bindings(), around_delivery: __MODULE__.Wrapper)

      returned = %{parcel_scan("parcel_scans/1/0009", "returned") | data: %{"kind" => "returned"}}

      assert StatifierRouter.route(config, returned, now: @now) ==
               {:ok, [{:no_match, "loaded_scans"}, {:no_match, "delivered_scans"}]}

      assert_received {:module_wrapped, "7c1e", :route}
    end
  end

  defmodule Wrapper do
    @moduledoc false
    def around_delivery(scope, door, work) do
      send(Process.get(:around_delivery_test_pid), {:module_wrapped, scope, door})
      work.()
    end
  end
end
