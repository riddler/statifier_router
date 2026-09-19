defmodule StatifierRouter.BroadwayTest do
  @moduledoc """
  The Broadway front, driven by `Broadway.DummyProducer` and Broadway's
  test helpers, over the real delivery against Postgres.

  Not async: the processors are processes of their own, so the SQL sandbox
  runs in shared mode, owned by the test process.
  """

  use ExUnit.Case, async: false

  doctest StatifierRouter.Broadway

  import ExUnit.CaptureLog
  import StatifierRouter.DeliveryFixtures

  alias Broadway.Message
  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierPersistence.Executions
  alias StatifierRouter.Config
  alias StatifierRouter.TestRepo

  # Every click stays in the one state, so every click is stepped and
  # logged, and the execution never finishes.
  @counter """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="counting">
    <state id="counting">
      <transition event="click"/>
    </state>
  </scxml>
  """

  defmodule RaisingDelivery do
    @moduledoc false
    def deliver(_config, _binding, _key, _delivery), do: raise("the repo went away")
  end

  setup do
    :ok = Sandbox.checkout(TestRepo)
    Sandbox.mode(TestRepo, {:shared, self()})
    :ok
  end

  describe "start_link/1" do
    # sabotage: start_link/1 let an unknown key through -> no
    # ArgumentError for :batchers, red; restored, green.
    test "refuses an unknown option, a missing one and an invalid one" do
      config = config(self())

      assert_raise ArgumentError, "unknown option :batchers", fn ->
        start(config, batchers: [])
      end

      assert_raise ArgumentError, "missing required option :router", fn ->
        StatifierRouter.Broadway.start_link(
          name: __MODULE__.Missing,
          producer: {Broadway.DummyProducer, []}
        )
      end

      assert_raise ArgumentError, ~r/invalid value for :producer/, fn ->
        start(config, producer: Broadway.DummyProducer)
      end

      assert_raise ArgumentError, ~r/invalid value for :normalize/, fn ->
        start(config, normalize: :not_a_fun)
      end

      assert_raise ArgumentError, ~r/expected a keyword list/, fn ->
        StatifierRouter.Broadway.start_link(:not_a_keyword_list)
      end
    end
  end

  describe "a pipeline with four processors" do
    # sabotage: start_link/1 partitioned every message by the hash of its
    # message id in place of partition/3 -> the input logs came back out
    # of send order, red; restored, green.
    test "keeps each key's clicks in send order in its execution's input log" do
      config = counter_config()
      pipeline = start(config, processors: [default: [concurrency: 4]])

      refs =
        for n <- 1..20 do
          impression_id = if rem(n, 2) == 0, do: "imp_a", else: "imp_b"

          Broadway.test_message(
            pipeline,
            %{"kind" => "click", "impression_id" => impression_id, "n" => n},
            metadata: %{scope: "7c1e", message_id: "ad_events/3/#{n}", source: "ad_events"}
          )
        end

      for ref <- refs, do: assert_receive({:ack, ^ref, [_], []}, 5_000)

      for {impression_id, sent} <- [
            {"imp_a", [2, 4, 6, 8, 10, 12, 14, 16, 18, 20]},
            {"imp_b", [1, 3, 5, 7, 9, 11, 13, 15, 17, 19]}
          ] do
        [execution_id] =
          for {"7c1e", "click_counter", ^impression_id, id} <- address_rows(config), do: id

        assert clicks_in_log(config, execution_id) == sent
      end

      stop(pipeline)
    end

    # sabotage: handle_message/3 returned the message unchanged on
    # {:error, reason} -> it arrived in the ack's successful list, red;
    # restored, green.
    test "a message route/3 answers {:error, reason} for is failed, not acknowledged" do
      config = config(self(), resolver: fn _scope, _document -> {:error, :unknown_document} end)
      pipeline = start(config, processors: [default: [concurrency: 4]])

      ref =
        Broadway.test_message(pipeline, impression().data,
          metadata: Map.take(impression(), [:scope, :message_id, :source])
        )

      assert_receive {:ack, ^ref, [], [%Message{status: {:failed, :unknown_document}}]}, 5_000
      assert executions() == 0
      assert input_rows() == 0

      stop(pipeline)
    end

    # sabotage: handle_message/3 returned the message unchanged on
    # {:error, reason} -> it arrived in the ack's successful list, red;
    # restored, green.
    test "a message the default normalize cannot build an event from is failed" do
      pipeline = start(config(self()), processors: [default: [concurrency: 4]])

      ref =
        Broadway.test_message(pipeline, impression().data,
          metadata: %{message_id: "ad_events/3/1042", source: "ad_events"}
        )

      assert_receive {:ack, ^ref, [], [%Message{status: {:failed, {:invalid_event, event}}}]},
                     5_000

      assert %{scope: nil, message_id: "ad_events/3/1042", source: "ad_events"} = event

      stop(pipeline)
    end

    # sabotage: handle_message/3 rescued the raise and returned the
    # message -> it arrived in the ack's successful list, red; restored,
    # green.
    test "a message whose delivery raises is failed, not acknowledged" do
      {:ok, config} =
        Config.new(repo: TestRepo, delivery: RaisingDelivery, bindings: bindings())

      pipeline = start(config, processors: [default: [concurrency: 4]])

      log =
        capture_log(fn ->
          ref =
            Broadway.test_message(pipeline, impression().data,
              metadata: Map.take(impression(), [:scope, :message_id, :source])
            )

          assert_receive {:ack, ^ref, [],
                          [
                            %Message{
                              status: {:error, %RuntimeError{message: "the repo went away"}, _}
                            }
                          ]},
                         5_000
        end)

      assert log =~ "the repo went away"

      stop(pipeline)
    end
  end

  describe "partition/3" do
    # sabotage: address/2 hashed the key alone in place of
    # {scope, document, key} -> the two scopes' clicks on one impression
    # hashed alike, red; restored, green. Second mutation: address/2 took
    # :none bindings too -> the :none binding's click hashed by its
    # address, red; restored, green. Third mutation: address/2 skipped the
    # match -> the click hashed by the conversion binding's address, red;
    # restored, green.
    test "hashes the address of the first binding that routes the event" do
      config = config(self())
      normalize = &StatifierRouter.Broadway.normalize/1

      impression = message(impression())
      click = message(click())
      other_click = message(click() |> put_in([:data, "impression_id"], "imp_9b2c"))
      other_scope = message(%{click() | scope: "4d0a"})

      imp_7f3a = :erlang.phash2({"7c1e", "impression_click_join", "imp_7f3a"})

      # The impression and its click address one execution through two
      # bindings, so they share a partition.
      assert StatifierRouter.Broadway.partition(impression, config, normalize) == imp_7f3a
      assert StatifierRouter.Broadway.partition(click, config, normalize) == imp_7f3a

      # Two keys land on two processors of four.
      other = StatifierRouter.Broadway.partition(other_click, config, normalize)
      assert other == :erlang.phash2({"7c1e", "impression_click_join", "imp_9b2c"})
      assert rem(other, 4) != rem(imp_7f3a, 4)

      assert StatifierRouter.Broadway.partition(other_scope, config, normalize) ==
               :erlang.phash2({"4d0a", "impression_click_join", "imp_7f3a"})

      # A binding whose match does not hold does not decide, though its key
      # would resolve for the event.
      conversions = %{
        id: "conversions_to_attribution",
        source: "ad_events",
        match: "event.kind == 'conversion'",
        key: "event.impression_id",
        document: "conversion_attribution",
        event: "conversion"
      }

      first_unmatched = config(self(), bindings: [conversions | bindings()])
      assert StatifierRouter.Broadway.partition(click, first_unmatched, normalize) == imp_7f3a

      # order: :none is no partition by key: the message id decides.
      unordered = config(self(), bindings: Enum.map(bindings(), &Map.put(&1, :order, :none)))

      assert StatifierRouter.Broadway.partition(click, unordered, normalize) ==
               :erlang.phash2("ad_events/3/1107")
    end

    # sabotage: address/2 took disabled bindings too -> the disabled
    # binding's click hashed by its address, red; restored, green. Second
    # mutation: by_message_id/1 hashed nil in place of the message id ->
    # red; restored, green.
    test "falls back to the message id when no binding addresses the event" do
      config = config(self())
      normalize = &StatifierRouter.Broadway.normalize/1

      # No binding matches a conversion.
      conversion = message(event("ad_events/3/1200", %{"kind" => "conversion"}))

      assert StatifierRouter.Broadway.partition(conversion, config, normalize) ==
               :erlang.phash2("ad_events/3/1200")

      # A click with no impression id: the binding matches, the key refuses.
      keyless = message(event("ad_events/3/1201", %{"kind" => "click"}))

      assert StatifierRouter.Broadway.partition(keyless, config, normalize) ==
               :erlang.phash2("ad_events/3/1201")

      # A disabled binding does not decide.
      disabled = config(self(), bindings: Enum.map(bindings(), &Map.put(&1, :enabled, false)))

      assert StatifierRouter.Broadway.partition(message(click()), disabled, normalize) ==
               :erlang.phash2("ad_events/3/1107")

      # A source no binding reads.
      elsewhere = message(%{click() | source: "page_views"})

      assert StatifierRouter.Broadway.partition(elsewhere, config, normalize) ==
               :erlang.phash2("ad_events/3/1107")
    end

    # sabotage: by_message_id/1 hashed nil in place of the message id ->
    # the scopeless click hashed as nil, red; restored, green.
    test "answers for a message normalize cannot build an event from" do
      config = config(self())

      no_scope = message(%{click() | scope: nil})

      assert StatifierRouter.Broadway.partition(
               no_scope,
               config,
               &StatifierRouter.Broadway.normalize/1
             ) == :erlang.phash2("ad_events/3/1107")

      assert StatifierRouter.Broadway.partition(message(click()), config, fn _ -> :nope end) ==
               :erlang.phash2(nil)
    end
  end

  defp start(config, opts) do
    name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      [name: name, producer: {Broadway.DummyProducer, []}, router: config]
      |> Keyword.merge(opts)
      |> StatifierRouter.Broadway.start_link()

    name
  end

  defp stop(pipeline) do
    ref = Process.monitor(Process.whereis(pipeline))
    Process.exit(Process.whereis(pipeline), :normal)
    assert_receive {:DOWN, ^ref, _, _, _}, 5_000
  end

  defp message(event) do
    %Message{
      data: event.data,
      metadata: Map.take(event, [:scope, :message_id, :source]),
      acknowledger: Broadway.NoopAcknowledger.init()
    }
  end

  defp counter_config do
    {:ok, machine} = Statifier.compile(@counter)
    content_hash = Statifier.Machine.identity(machine).content_hash

    config(self(),
      resolver: fn _scope, "click_counter" -> {content_hash, machine} end,
      chart_resolver: fn ^content_hash -> {:ok, machine} end,
      bindings: [
        %{
          id: "clicks_to_count",
          source: "ad_events",
          match: "event.kind == 'click'",
          key: "event.impression_id",
          document: "click_counter",
          event: "click",
          data: ["impression_id", "n"]
        }
      ]
    )
  end

  defp address_rows(config) do
    for address <- addresses(config),
        do: {address.scope, address.document, address.key, address.execution_id}
  end

  defp clicks_in_log(config, execution_id) do
    {:ok, entries} = Executions.inputs(config.store, execution_id)
    Enum.map(entries, & &1.event.data["n"])
  end
end
