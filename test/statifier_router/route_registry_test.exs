defmodule StatifierRouter.HalfTimerQueue do
  @moduledoc """
  A queue that schedules and cannot cancel: what
  `StatifierRouter.TimerQueue.valid?/1` has to refuse, and the only shape
  that tells a check of both callbacks apart from a check of the first.
  """

  @spec schedule(map(), StatifierRouter.TimerQueue.entry()) :: :ok
  def schedule(_queue_config, _entry), do: :ok
end

defmodule StatifierRouter.RouteRegistryTest do
  use ExUnit.Case, async: true

  alias Statifier.Send.Routes
  alias Statifier.Send.Types
  alias StatifierRouter.Config
  alias StatifierRouter.RecordingDelivery
  alias StatifierRouter.RecordingRoute
  alias StatifierRouter.RecordingTimerQueue
  alias StatifierRouter.Route
  alias StatifierRouter.SendHandler
  alias StatifierRouter.TestRepo
  alias StatifierRouter.TimerQueue

  doctest Route
  doctest TimerQueue

  @delivery RecordingDelivery
  @joined {RecordingRoute, %{sink: "joined_records"}}
  @dead_letter {RecordingRoute, %{sink: "dead_letter"}}
  @adapters %{"joined_records" => @joined, "dead_letter" => @dead_letter}

  defp config(opts \\ []) do
    {:ok, config} =
      [repo: TestRepo, delivery: @delivery, route_adapters: @adapters]
      |> Keyword.merge(opts)
      |> Config.new()

    config
  end

  describe "Route.valid?/1" do
    # sabotage: valid?/1 dropped the function_exported? conjunct -> a
    # module that exports no deliver/3 was accepted, red; restored, green.
    test "holds an adapter to the behaviour's own callback" do
      assert Route.valid?(RecordingRoute)
      refute Route.valid?(Config)
      refute Route.valid?(:not_a_module)
      refute Route.valid?(nil)
      refute Route.valid?("joined_records")
    end
  end

  describe "TimerQueue.valid?/1" do
    # sabotage: valid?/1 checked schedule/2 only -> a module exporting no
    # cancel/3 was accepted, red; restored, green.
    test "holds a queue to both of the behaviour's callbacks" do
      assert TimerQueue.valid?(RecordingTimerQueue)
      refute TimerQueue.valid?(StatifierRouter.HalfTimerQueue)
      refute TimerQueue.valid?(RecordingRoute)
      refute TimerQueue.valid?(%{})
    end
  end

  describe "the registry on Config.new/1" do
    # sabotage: route_adapters/1 answered {:ok, given} unconditionally ->
    # a bare module in place of {module, config} was accepted, red;
    # restored, green.
    test "takes a map from route name to an adapter and its configuration" do
      assert %Config{route_adapters: @adapters, route_overrides: %{}} = config()

      assert %Config{route_adapters: %{}} =
               config(route_adapters: %{}) |> tap(&assert &1.route_overrides == %{})

      for refused <- [
            %{"joined_records" => RecordingRoute},
            %{"joined_records" => {Config, %{}}},
            %{"" => @joined},
            %{joined_records: @joined},
            %{"joined_records" => {RecordingRoute, [sink: "x"]}},
            []
          ] do
        assert Config.new(repo: TestRepo, delivery: @delivery, route_adapters: refused) ==
                 {:error, {:invalid_value, :route_adapters, refused}}
      end
    end

    # sabotage: unregistered_override/2 answered {:ok, given} without
    # looking for a name the registry lacks -> the override on an
    # unregistered route was accepted, red; restored, green.
    test "refuses an override that names a route the host did not register" do
      assert Config.new(
               repo: TestRepo,
               delivery: @delivery,
               route_adapters: @adapters,
               route_overrides: %{"staging" => %{"audit_log" => %{sink: "staging_audit"}}}
             ) == {:error, {:unregistered_route, "staging", "audit_log"}}

      assert %Config{route_overrides: %{"staging" => %{"joined_records" => %{sink: "staging"}}}} =
               config(route_overrides: %{"staging" => %{"joined_records" => %{sink: "staging"}}})
    end

    # sabotage: send_type/1 accepted any term -> an atom send type was
    # accepted and reached the snapshot, red; restored, green.
    test "takes the one type string the handler answers to" do
      assert %Config{send_type: "myapp:sink"} = config(send_type: "myapp:sink")
      assert %Config{send_type: nil} = config()

      for refused <- [:"myapp:sink", "", 7] do
        assert Config.new(repo: TestRepo, delivery: @delivery, send_type: refused) ==
                 {:error, {:invalid_value, :send_type, refused}}
      end
    end

    # sabotage: timer_queue/1 skipped TimerQueue.valid?/1 -> a module
    # serving neither callback was accepted, red; restored, green.
    test "takes a timer queue as a module and its configuration" do
      queue = {RecordingTimerQueue, %{}}
      assert %Config{timer_queue: ^queue} = config(timer_queue: queue)
      assert %Config{timer_queue: nil} = config()

      for refused <- [RecordingTimerQueue, {RecordingRoute, %{}}, {RecordingTimerQueue, []}] do
        assert Config.new(repo: TestRepo, delivery: @delivery, timer_queue: refused) ==
                 {:error, {:invalid_value, :timer_queue, refused}}
      end
    end
  end

  describe "the send-types snapshot ADR-0005 decision 6 hands over" do
    # sabotage: persistence_options/2 ignored send_type and answered the
    # given list -> the created execution carried no snapshot and the
    # registered type was undeclared, red; restored, green.
    test "is built from the type string and the handler, and rides in :persistence_options" do
      %Config{persistence_options: options} = config(send_type: "myapp:sink")

      assert Keyword.fetch!(options, :send_types) ==
               Types.from_send_types(%{"myapp:sink" => SendHandler})

      assert %Config{persistence_options: []} = config()
    end

    # sabotage: the Keyword.has_key?(given, :send_types) clause removed ->
    # the derived snapshot was appended beside the host's and the later
    # one silently won, red; restored, green.
    test "refuses to compete with a :send_types the host declared itself" do
      declared = Types.from_send_types(%{"myapp:other" => SendHandler})

      assert Config.new(
               repo: TestRepo,
               delivery: @delivery,
               send_type: "myapp:sink",
               persistence_options: [send_types: declared]
             ) == {:error, {:declared_send_types, "myapp:sink"}}
    end

    # sabotage: @route_keys dropped from @known -> every route option was
    # refused as unknown, red; restored, green.
    test "leaves the engine's own :routes in :persistence_options alone" do
      snapshot = [routes: Routes.new()]

      %Config{persistence_options: options, route_adapters: adapters} =
        config(send_type: "myapp:sink", persistence_options: snapshot)

      assert Keyword.fetch!(options, :routes) == Routes.new()
      assert Map.has_key?(adapters, "joined_records")
      refute Keyword.has_key?(snapshot, :send_types)
    end
  end

  describe "Config.route/3" do
    # sabotage: route/3 merged the registered configuration over the
    # override instead of the override over it -> the scope's sink did
    # not win, red; restored, green.
    test "applies the scope's override over the registered configuration" do
      config =
        config(route_overrides: %{"staging" => %{"joined_records" => %{sink: "staging_sink"}}})

      assert Config.route(config, "staging", "joined_records") ==
               {:ok, {RecordingRoute, %{sink: "staging_sink"}}}

      assert Config.route(config, "7c1e", "joined_records") == {:ok, @joined}
      assert Config.route(config, nil, "joined_records") == {:ok, @joined}
      assert Config.route(config, "staging", "dead_letter") == {:ok, @dead_letter}
    end

    # sabotage: the :error clause of Map.fetch/2 answered {:ok, {nil, %{}}}
    # -> an unregistered route resolved to a nil adapter, red; restored,
    # green.
    test "misses a route the host did not register, in every scope" do
      config = config(route_overrides: %{"staging" => %{"joined_records" => %{}}})

      assert Config.route(config, "staging", "audit_log") == :error
      assert Config.route(config, nil, "audit_log") == :error
      assert Config.route(config, "7c1e", nil) == :error
    end
  end
end
