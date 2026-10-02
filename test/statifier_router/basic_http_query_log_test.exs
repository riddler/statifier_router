defmodule StatifierRouter.BasicHTTPQueryLogTest do
  # Not async: the test raises the global logger level to :debug, which
  # every test running beside it would print under.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import StatifierRouter.DeliveryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias StatifierRouter.BasicHTTP
  alias StatifierRouter.BasicHTTP.Front
  alias StatifierRouter.TestRepo

  # ADR-0002, the Note of 2026-10-02: the three statements that bind a
  # BasicHTTP location token run with `log: false`, so this package's own
  # Ecto query log never prints the token at :debug.

  @base_url "https://depot.example/scxml"
  @now ~U[2026-10-02 08:00:00.000000Z]
  @form "application/x-www-form-urlencoded"

  setup do
    :ok = Sandbox.checkout(TestRepo)
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
    :ok
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

  # One entry per log event: the console format opens each with its
  # level in brackets.
  defp entries(log), do: String.split(log, ~r/(?=\[(debug|info|notice|warning|error)\])/)

  # The entries this package's own statements print: the ones that name
  # one of its tables. A capture around a create also holds the
  # persistence package's execution INSERT and UPDATE, whose position_blob
  # carries the location inside the execution's _ioprocessors (Ecto's
  # inspect limit cuts the blob short, so the token is unreadable there,
  # not absent). Those statements are that package's, not this one's, and
  # the assertion is scoped away from them.
  defp router_entries(log), do: Enum.filter(entries(log), &(&1 =~ "statifier_router_"))

  describe "the debug query log" do
    # sabotage: log: false dropped from the front's lookup in resolve/2 ->
    # the address-join SELECT logged the token, red; restored, green.
    # sabotage: log: false dropped from locate/3's location insert -> the
    # create's INSERT logged the token, red; restored, green.
    # sabotage: log: false dropped from rotate_location/2's upsert -> the
    # rotation's INSERT ... ON CONFLICT logged the token, red; restored,
    # green.
    test "prints no location token on the lookup, the create's insert or the rotation" do
      config = config(self(), bindings: parcel_bindings(), basichttp: [base_url: @base_url])

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, [{:created_and_delivered, "loaded_scans", execution_id}, _]} =
                   StatifierRouter.route(config, parcel_scan("parcel_scans/1/0001", "loaded"),
                     now: @now
                   )

          {:ok, created} = BasicHTTP.location(config, execution_id)

          assert Front.handle(config, post(token(created), "noted"), now: @now) ==
                   {:ok, {:delivered, "basichttp", execution_id}}

          assert {:ok, rotated} = BasicHTTP.rotate_location(config, execution_id)

          assert Front.handle(config, post(token(rotated), "noted"), now: @now) ==
                   {:ok, {:delivered, "basichttp", execution_id}}

          send(self(), {:tokens, token(created), token(rotated)})
        end)

      assert_received {:tokens, created, rotated}

      router = router_entries(log)

      # The capture saw this package's statements at :debug at all: the
      # address lookups and the ledger inserts print, carrying no token.
      assert Enum.any?(router, &(&1 =~ "statifier_router_addresses"))

      for entry <- router, token <- [created, rotated] do
        refute String.contains?(entry, token), "a router statement logged the token:\n" <> entry
      end
    end
  end
end
