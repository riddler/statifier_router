defmodule StatifierRouter.BasicHTTPTest do
  use ExUnit.Case, async: true, group: :database

  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Statifier.Send.Types
  alias Statifier.Session
  alias StatifierPersistence.Executions
  alias StatifierRouter.BasicHTTP
  alias StatifierRouter.BasicHTTP.Front
  alias StatifierRouter.Config
  alias StatifierRouter.Schema.{Address, Ledger, Location}
  alias StatifierRouter.TestRepo

  doctest StatifierRouter.BasicHTTP.Front

  # ADR-0002, the Amendment of 2026-09-30: a durable execution's BasicHTTP
  # location is a token the router mints beside the address row, and the
  # front delivers a POST at it through the existing delivery path.

  @base_url "https://depot.example/scxml"
  @now ~U[2026-09-30 08:00:00.000000Z]
  @form "application/x-www-form-urlencoded"
  @uri "http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor"

  # A well-formed send key: eight `/`-separated fields.
  @send_key "sess_depot/scan_1/3/1/0/0/onentry.0.0/0"

  # A session module that refuses the processor's short form after
  # handing the URI's re-stamp to the engine: the partial re-stamp.
  defmodule RefusesShortForm do
    @moduledoc false
    def replace_send_type(_session, "basichttp", _registration), do: {:error, :not_running}

    def replace_send_type(session, type, registration),
      do: Statifier.Session.replace_send_type(session, type, registration)
  end

  # A session module whose engine exports no replace_send_type/3.
  defmodule NoReplaceSendType do
    @moduledoc false
    def refresh_ioprocessors(_session), do: :ok
  end

  setup do
    :ok = Sandbox.checkout(TestRepo)
    :ok
  end

  defp basichttp_config(opts \\ []) do
    config(
      self(),
      Keyword.merge([bindings: parcel_bindings(), basichttp: [base_url: @base_url]], opts)
    )
  end

  # A parcel loaded onto the van: the execution the location reaches.
  defp loaded_parcel(config, message_id \\ "parcel_scans/1/0001", parcel_id \\ "pcl_4821") do
    scan = %{
      parcel_scan(message_id, "loaded")
      | data: %{"kind" => "loaded", "parcel_id" => parcel_id}
    }

    assert {:ok, [{:created_and_delivered, "loaded_scans", execution_id}, _]} =
             StatifierRouter.route(config, scan, now: @now)

    assert {:ok, location} = BasicHTTP.location(config, execution_id)
    {execution_id, location}
  end

  defp token(location), do: String.replace_prefix(location, @base_url <> "/", "")

  defp post(token, event, overrides \\ %{}) do
    Map.merge(
      %{
        token: token,
        method: "POST",
        content_type: @form,
        body: "_scxmleventname=" <> event,
        query: nil,
        send_key: nil
      },
      overrides
    )
  end

  defp handle(config, request), do: Front.handle(config, request, now: @now)

  describe "the location" do
    # sabotage: locate/3 in StatifierRouter.Delivery made to skip every
    # configuration -> no location row was written and location/2
    # answered {:error, :no_location}, red; restored, green.
    # sabotage: mint_token/0 made to pad its base64 -> red on the token's
    # shape; restored, green.
    test "is minted from the base URL and a token, never the execution id" do
      config = basichttp_config()
      {execution_id, location} = loaded_parcel(config)

      assert String.starts_with?(location, @base_url <> "/")
      token = token(location)
      assert token =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      refute String.contains?(location, execution_id)
    end

    # sabotage: create_persistence_options/2 made to answer the
    # configuration's own snapshot whatever the token -> the created
    # execution's entry carried no location, red; restored, green.
    test "is the one the created execution's _ioprocessors carries, under both type strings" do
      pid = self()

      on_create = fn store, execution_id, machine, opts ->
        result = Executions.create(store, execution_id, machine, opts)
        {:ok, _execution, state} = result
        send(pid, {:created, state.datamodel["_ioprocessors"]})
        result
      end

      config = basichttp_config(on_create: on_create)
      {_execution_id, location} = loaded_parcel(config)

      assert_received {:created, ioprocessors}
      assert ioprocessors["basichttp"] == %{"location" => location}
      assert ioprocessors[@uri] == %{"location" => location}
    end

    # sabotage: ioprocessors_entry/2's no-token clause made to answer a
    # location -> red on the always_new entry; restored, green.
    test "is absent for an always_new execution, which rotation refuses" do
      pid = self()

      on_create = fn store, execution_id, machine, opts ->
        result = Executions.create(store, execution_id, machine, opts)
        {:ok, _execution, state} = result
        send(pid, {:created, state.datamodel["_ioprocessors"]})
        result
      end

      bindings = Enum.map(parcel_bindings(), &Map.put(&1, :create, :always_new))
      config = basichttp_config(bindings: bindings, on_create: on_create)

      {:ok, [{:created_and_delivered, "loaded_scans", execution_id}, _]} =
        StatifierRouter.route(config, parcel_scan("parcel_scans/1/0001", "loaded"), now: @now)

      assert_received {:created, %{"basichttp" => entry}}
      assert entry == %{}
      assert BasicHTTP.location(config, execution_id) == {:error, :no_location}

      assert BasicHTTP.rotate_location(config, execution_id) ==
               {:error, {:no_address, execution_id}}

      assert TestRepo.all(Config.queryable(config, Location)) == []
    end

    # sabotage: rotate_location/2's insert made to leave the token as it
    # was on a conflict -> the old token still delivered, red; restored,
    # green.
    test "rotates: the old token answers 404 and the new one delivers" do
      config = basichttp_config()
      {execution_id, old} = loaded_parcel(config)

      assert {:ok, new} = BasicHTTP.rotate_location(config, execution_id)
      assert new != old
      assert BasicHTTP.location(config, execution_id) == {:ok, new}

      answer = handle(config, post(token(old), "noted"))
      assert answer == {:error, :unknown_location}
      assert Front.response(answer) == {404, []}

      answer = handle(config, post(token(new), "noted"))
      assert answer == {:ok, {:delivered, "basichttp", execution_id}}
      assert Front.response(answer) == {204, []}
    end

    # sabotage: rotate_location/2's insert made an update of an existing
    # location only -> the row got no location and the POST answered
    # unknown_location, red; restored, green.
    test "is given by rotation to an address row written before the key was set" do
      plain = config(self(), bindings: parcel_bindings())

      {:ok, [{:created_and_delivered, "loaded_scans", execution_id}, _]} =
        StatifierRouter.route(plain, parcel_scan("parcel_scans/1/0001", "loaded"), now: @now)

      config = basichttp_config()
      assert BasicHTTP.location(config, execution_id) == {:error, :no_location}
      assert {:ok, location} = BasicHTTP.rotate_location(config, execution_id)

      assert handle(config, post(token(location), "noted")) ==
               {:ok, {:delivered, "basichttp", execution_id}}
    end
  end

  describe "rotation with a live session" do
    # A live session over the parcel chart, registered as a create
    # registers the processor: this module under each of `types`, the
    # location's token among its options.
    defp live_session(location, start_opts \\ [], types \\ BasicHTTP.type_strings()) do
      registration = Config.basichttp_registration([base_url: @base_url], token(location))
      send_types = Map.new(types, &{&1, registration})
      {:ok, machine} = Map.fetch(machines(), "parcel_route")
      {:ok, session} = Session.start_link(machine, [send_types: send_types] ++ start_opts)
      session
    end

    defp ioprocessors(session), do: Session.snapshot(session).datamodel["_ioprocessors"]

    # sabotage: rotate_location/4 made to answer {:ok, location} without
    # calling restamp/5 -> both entries kept the old location, red;
    # restored, green.
    # sabotage: Config.basichttp_registration/2's token clause made to
    # leave the token out -> the session's entries carried no location,
    # red; restored, green.
    test "re-stamps the session's entry under both type strings" do
      config = basichttp_config()
      {execution_id, old} = loaded_parcel(config)
      session = live_session(old)
      assert ioprocessors(session)[@uri] == %{"location" => old}

      assert {:ok, new} = BasicHTTP.rotate_location(config, execution_id, session: session)
      assert new != old
      assert BasicHTTP.location(config, execution_id) == {:ok, new}
      assert ioprocessors(session)[@uri] == %{"location" => new}
      assert ioprocessors(session)["basichttp"] == %{"location" => new}
    end

    # sabotage: the no-session branch of rotate_location/4 made to answer
    # {:error, {:no_address, execution_id}} -> no match, red; restored,
    # green.
    test "with no options answers as rotate_location/2 and asks no session" do
      config = basichttp_config()
      {execution_id, old} = loaded_parcel(config)
      session = live_session(old)

      assert {:ok, new} = BasicHTTP.rotate_location(config, execution_id, [])
      assert BasicHTTP.location(config, execution_id) == {:ok, new}
      assert {:ok, newer} = BasicHTTP.rotate_location(config, execution_id)
      assert BasicHTTP.location(config, execution_id) == {:ok, newer}
      assert ioprocessors(session)[@uri] == %{"location" => old}
    end

    # sabotage: the Keyword.validate!/2 call removed -> no ArgumentError
    # was raised and the token moved, red; restored, green.
    test "raises ArgumentError for an unknown option and writes nothing" do
      config = basichttp_config()
      {execution_id, old} = loaded_parcel(config)

      assert_raise ArgumentError, fn ->
        BasicHTTP.rotate_location(config, execution_id, sesion: self())
      end

      assert BasicHTTP.location(config, execution_id) == {:ok, old}
    end

    # sabotage: the no-address clause made to re-stamp the named session
    # with a fresh token -> the session's entry moved, red; restored,
    # green.
    test "answers no_address as before and leaves the session alone" do
      config = basichttp_config()
      {_execution_id, old} = loaded_parcel(config)
      session = live_session(old)

      assert BasicHTTP.rotate_location(config, "exec_unknown", session: session) ==
               {:error, {:no_address, "exec_unknown"}}

      assert ioprocessors(session)[@uri] == %{"location" => old}
    end

    # sabotage: restamp_type/5's refusal clause made to answer
    # {:ok, location} -> the not_running refusal answered ok, red;
    # restored, green.
    test "answers the engine's not_running for a halted session, the token moved" do
      config = basichttp_config()
      {execution_id, old} = loaded_parcel(config)
      session = live_session(old)
      Session.send_event(session, "loaded")
      Session.send_event(session, "delivered")
      assert Session.status(session).status == :done

      assert {:error, {:session_not_restamped, new, :not_running}} =
               BasicHTTP.rotate_location(config, execution_id, session: session)

      assert new != old
      assert BasicHTTP.location(config, execution_id) == {:ok, new}
    end

    # sabotage: restamp_type/5's refusal clause made to drop the location
    # from the error ({:session_not_restamped, reason}) -> no match, red;
    # restored, green.
    test "answers the engine's recorded_session for a recording session" do
      config = basichttp_config()
      {execution_id, old} = loaded_parcel(config)
      session = live_session(old, record: true)

      assert {:error, {:session_not_restamped, new, :recorded_session}} =
               BasicHTTP.rotate_location(config, execution_id, session: session)

      assert BasicHTTP.location(config, execution_id) == {:ok, new}
      assert ioprocessors(session)[@uri] == %{"location" => old}
    end

    # sabotage: restamp/5 made to ask every type string and answer the
    # last refusal -> the reason named basichttp, not the URI, red;
    # restored, green.
    test "stops at a refused URI and answers its reason" do
      config = basichttp_config()
      {execution_id, old} = loaded_parcel(config)
      session = live_session(old, [], [])

      assert {:error, {:session_not_restamped, new, {:unknown_send_type, @uri}}} =
               BasicHTTP.rotate_location(config, execution_id, session: session)

      assert BasicHTTP.location(config, execution_id) == {:ok, new}
    end

    # sabotage: type_strings/0 made to answer the short form first -> the
    # basichttp refusal came first and the URI entry kept the old
    # location, red; restored, green.
    test "a refused basichttp after the URI leaves the URI entry re-stamped" do
      config = basichttp_config()
      {execution_id, old} = loaded_parcel(config)
      session = live_session(old, [], [@uri])

      assert {:error, {:session_not_restamped, new, {:unknown_send_type, "basichttp"}}} =
               BasicHTTP.rotate_location(config, execution_id, session: session)

      assert ioprocessors(session)[@uri] == %{"location" => new}
    end

    # sabotage: restamp/5 made to re-stamp the URI alone -> the partial
    # answered ok, red; restored, green.
    test "a partial re-stamp leaves basichttp carrying the old location" do
      config = basichttp_config()
      {execution_id, old} = loaded_parcel(config)
      session = live_session(old)

      assert {:error, {:session_not_restamped, new, :not_running}} =
               BasicHTTP.rotate_location(
                 config,
                 execution_id,
                 [session: session],
                 __MODULE__.RefusesShortForm
               )

      assert ioprocessors(session)[@uri] == %{"location" => new}
      assert ioprocessors(session)["basichttp"] == %{"location" => old}
    end

    # sabotage: the unavailable refusal's atom renamed to :unavailable ->
    # no match, red; restored, green.
    test "answers replace_send_type_unavailable when the engine exports no such call" do
      config = basichttp_config()
      {execution_id, old} = loaded_parcel(config)
      session = live_session(old)

      assert {:error, {:session_not_restamped, new, :replace_send_type_unavailable}} =
               BasicHTTP.rotate_location(
                 config,
                 execution_id,
                 [session: session],
                 __MODULE__.NoReplaceSendType
               )

      assert BasicHTTP.location(config, execution_id) == {:ok, new}
      assert ioprocessors(session)[@uri] == %{"location" => old}
    end

    # sabotage: rotate_location/4 made to ask the session for its status
    # before the upsert -> the exit left the old location in place, red;
    # restored, green.
    test "a session that is not alive exits the caller after the token moved" do
      config = basichttp_config()
      {execution_id, old} = loaded_parcel(config)
      session = live_session(old)
      :ok = Session.stop(session)

      assert {:noproc, _call} =
               catch_exit(BasicHTTP.rotate_location(config, execution_id, session: session))

      assert {:ok, new} = BasicHTTP.location(config, execution_id)
      assert new != old
    end
  end

  describe "the front" do
    # sabotage: deliver/5 in the front handed deliver_event/4 the plan
    # with the row's key replaced by "pcl_other" -> the :never lookup
    # missed and the answer was dropped: no_execution, red; restored,
    # green.
    test "delivers a POST to a persisted execution and answers 204" do
      config = basichttp_config()
      {execution_id, location} = loaded_parcel(config)

      answer = handle(config, post(token(location), "delivered"))

      assert answer == {:ok, {:delivered, "basichttp", execution_id}}
      assert Front.response(answer) == {204, []}
      assert inputs(config, execution_id) == [{0, "step", "loaded"}, {1, "step", "delivered"}]

      assert %Ledger{
               binding_id: "basichttp",
               scope: "7c1e",
               outcome: "delivered",
               key: "pcl_4821",
               execution_id: ^execution_id
             } = List.last(ledger(config))
    end

    # sabotage: address_by_token/2's where dropped -> a well-shaped
    # unknown token resolved to the one location row and delivered, red;
    # restored, green.
    test "answers 404 for an unknown location and writes nothing" do
      config = basichttp_config()
      {_execution_id, _location} = loaded_parcel(config)
      before = ledger(config)

      for token <- [BasicHTTP.mint_token(), "not-a-token"] do
        answer = handle(config, post(token, "delivered"))
        assert answer == {:error, :unknown_location}
        assert Front.response(answer) == {404, []}
      end

      assert ledger(config) == before
    end

    # sabotage: response/1's {:not_utf8, _} clause deleted -> the malformed
    # body answered 500, red; restored, green.
    test "answers 400 for a malformed body and delivers nothing" do
      config = basichttp_config()
      {execution_id, location} = loaded_parcel(config)

      answer = handle(config, post(token(location), "delivered", %{body: <<0xFF, 0xFE>>}))

      assert answer == {:error, {:not_utf8, :body}}
      assert Front.response(answer) == {400, []}
      assert inputs(config, execution_id) == [{0, "step", "loaded"}]
    end

    # sabotage: response/1's :method_not_allowed clause answered no allow
    # header -> red on the headers; restored, green.
    test "answers 405 with Allow: POST for a method other than POST" do
      config = basichttp_config()
      {execution_id, location} = loaded_parcel(config)

      answer = handle(config, post(token(location), "delivered", %{method: "GET"}))

      assert answer == {:error, {:method_not_allowed, "GET"}}
      assert Front.response(answer) == {405, [{"allow", "POST"}]}
      assert inputs(config, execution_id) == [{0, "step", "loaded"}]
    end

    # sabotage: message_id/2 made to mint a fresh id whatever the send key
    # -> the second POST was delivered again, red; restored, green.
    test "deduplicates on the scxml-send-key per execution" do
      config = basichttp_config()
      {first, first_location} = loaded_parcel(config)
      {second, second_location} = loaded_parcel(config, "parcel_scans/1/0002", "pcl_5190")

      request = post(token(first_location), "noted", %{send_key: @send_key})

      assert handle(config, request) == {:ok, {:delivered, "basichttp", first}}
      assert handle(config, request) == {:ok, {:duplicate, "basichttp"}}
      assert Front.response({:ok, {:duplicate, "basichttp"}}) == {204, []}
      assert inputs(config, first) == [{0, "step", "loaded"}, {1, "step", "noted"}]

      # The same key at another execution's location is another message.
      assert handle(config, %{request | token: token(second_location)}) ==
               {:ok, {:delivered, "basichttp", second}}

      # Without a key every POST is its own message.
      no_key = post(token(first_location), "noted")
      assert handle(config, no_key) == {:ok, {:delivered, "basichttp", first}}
      assert handle(config, no_key) == {:ok, {:delivered, "basichttp", first}}
    end

    # sabotage: resolve/2 matched any address row, stamped or not -> the
    # retry was claimed as a duplicate and answered 204, red; restored,
    # green.
    test "answers 404 for a finished execution, and again for the retry" do
      config = basichttp_config()
      {execution_id, location} = loaded_parcel(config)

      assert {:ok, {:delivered, "basichttp", ^execution_id}} =
               handle(config, post(token(location), "delivered"))

      request = post(token(location), "noted", %{send_key: @send_key})
      answer = handle(config, request)
      assert answer == {:ok, {:dropped, "basichttp", :finished}}
      assert Front.response(answer) == {404, []}

      assert handle(config, request) == {:error, :unknown_location}
    end

    # sabotage: dropped :query from @required -> the refusal named :body
    # alone, red; restored, green.
    test "refuses a malformed request by naming its keys, never the token" do
      config = basichttp_config()
      {_execution_id, location} = loaded_parcel(config)

      request = Map.drop(post(token(location), "noted"), [:body, :query])

      answer = handle(config, request)
      assert answer == {:error, {:invalid_request, [:body, :query]}}
      assert Front.response(answer) == {500, []}
      refute inspect(answer) =~ token(location)

      assert Front.handle(config, post(token(location), "noted"), then: @now) ==
               {:error, {:unknown_key, :then}}
    end

    # sabotage: not_reentrant/0 made to answer :ok -> the POST from inside
    # a route delivered, red; restored, green.
    test "refuses while a route runs in the calling process" do
      config = basichttp_config()
      {execution_id, location} = loaded_parcel(config)

      Process.put({StatifierRouter.SendHandler, :in_route}, execution_id)

      try do
        assert handle(config, post(token(location), "noted")) ==
                 {:error, {:reentrant_route, execution_id}}
      after
        Process.delete({StatifierRouter.SendHandler, :in_route})
      end
    end
  end

  describe "the configuration" do
    # sabotage: put_basichttp/3's nil clause made to register the
    # processor anyway -> the snapshot differed, red; restored, green.
    test "without :basichttp mints nothing and builds the snapshot as before" do
      plain = config(self(), bindings: parcel_bindings(), send_type: "myapp:router")
      assert plain.basichttp == nil

      {:ok, [{:created_and_delivered, "loaded_scans", _id}, _]} =
        StatifierRouter.route(plain, parcel_scan("parcel_scans/1/0001", "loaded"), now: @now)

      assert TestRepo.all(Config.queryable(plain, Location)) == []
      assert [%Address{}] = addresses(plain)

      assert plain.persistence_options == [
               send_types:
                 Types.from_send_types(%{
                   "myapp:router" => StatifierRouter.SendHandler
                 })
             ]
    end

    # sabotage: basichttp_shape/1 made to accept any keyword list -> the
    # empty base URL was accepted, red; restored, green.
    test "refuses a malformed :basichttp and a clash with another registration" do
      base = [repo: TestRepo, delivery: StatifierRouter.RecordingDelivery]

      for bad <- [[], [base_url: ""], [base_url: 7], [transport: Foo], [base_url: "x", port: 1]] do
        assert Config.new(base ++ [basichttp: bad]) == {:error, {:invalid_value, :basichttp, bad}}
      end

      ok = [base_url: @base_url]

      assert Config.new(base ++ [basichttp: ok, send_handlers: %{"basichttp" => Foo}]) ==
               {:error, {:declared_send_types, "basichttp"}}

      assert Config.new(base ++ [basichttp: ok, send_type: @uri]) ==
               {:error, {:declared_send_types, @uri}}

      assert Config.new(base ++ [basichttp: ok, persistence_options: [send_types: nil]]) ==
               {:error, {:exclusive_keys, :basichttp, :send_types}}
    end

    # sabotage: refuse_reserved_id/2 made to reserve basichttp on every
    # configuration -> red on the configuration without the key; restored,
    # green.
    test "reserves the binding id basichttp only when the key is set" do
      base = [repo: TestRepo, delivery: StatifierRouter.RecordingDelivery]
      binding = hd(parcel_bindings()) |> Map.put(:id, "basichttp")

      assert {:ok, %Config{}} = Config.new(base ++ [bindings: [binding]])

      assert Config.new(base ++ [bindings: [binding], basichttp: [base_url: @base_url]]) ==
               {:error, {:reserved_binding_id, "basichttp"}}

      resolved =
        Config.new(
          base ++
            [
              bindings_resolver: fn _scope -> [elem(StatifierRouter.Binding.new(binding), 1)] end,
              basichttp: [base_url: @base_url]
            ]
        )

      assert {:ok, config} = resolved
      assert Config.bindings_for(config, "7c1e") == {:error, {:reserved_binding_id, "basichttp"}}
    end
  end
end
