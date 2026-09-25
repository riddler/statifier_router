defmodule StatifierRouter.MixProject do
  use Mix.Project

  @version "0.4.1"
  @source_url "https://github.com/riddler/statifier_router"

  def project do
    [
      app: :statifier_router,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "StatifierRouter",
      description:
        "A Broadway front and a binding, addressing and delivery layer that " <>
          "routes external events to durable statifier executions, creating " <>
          "them when absent",
      source_url: @source_url,
      docs: docs(),
      package: package(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:ex_unit]],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  # No mod: entry. This package owns no process: the host starts the
  # Broadway pipeline in its own supervision tree and schedules the reapers.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # `mix coveralls` imports the cover data the gate's "Isolated tests"
  # stage exports into cover/, so the whole-suite figure and its floor
  # count the :isolated modules too (.quality.exs says why the suite is
  # split). The import lives here rather than in the Tests stage's args
  # because the gate passes those args to plain `mix test` as well, on
  # `--quick` and on a `--test-scope` run, and `mix test` refuses an
  # excoveralls switch. An alias of the same name runs the task itself.
  #
  # A directory with no .coverdata imports nothing. A `mix coveralls` run
  # by hand imports whatever export the last gate left in cover/; only
  # the full gate's figure, which rewrites that export first, is the one
  # to trust.
  defp aliases do
    [
      coveralls: ["coveralls --import-cover cover"]
    ]
  end

  defp docs do
    [
      name: "StatifierRouter",
      source_ref: "v#{@version}",
      canonical: "https://hexdocs.pm/statifier_router",
      source_url: @source_url,
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      # Names the docs print as code on purpose but that have no page to
      # link to, so ExDoc renders them as plain code rather than warning.
      # `StatifierRouter.SendHandler.perform/2` is the send processor's
      # callback, hidden by its `@impl`; `StatifierRouter.TimerQueue`'s
      # moduledoc names it as the writer of a session-scoped row. Each term
      # is exact: any other reference that resolves nowhere still warns.
      skip_code_autolink_to: [
        "StatifierRouter.SendHandler.perform/2"
      ]
    ]
  end

  defp package do
    [
      name: "statifier_router",
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "statifier" => "https://hexdocs.pm/statifier",
        "statifier_persistence" => "https://hexdocs.pm/statifier_persistence"
      }
    ]
  end

  defp deps do
    [
      # Required, not optional: the Broadway front is the package's entry
      # point, and the host starts it in its own tree.
      {:broadway, "~> 1.3"},
      {:statifier, "~> 2.7"},
      {:statifier_persistence, "~> 0.13"},
      {:predicator, "~> 9.4"},
      {:ecto_sql, "~> 3.14"},
      # The execution ids the router mints (ADR-0002, section 3): the same
      # uxid statifier_persistence already requires for its own keys.
      {:uxid, "~> 2.0"},
      # The no_match telemetry event (ADR-0004, section 5).
      {:telemetry, "~> 1.0"},

      # Dev / test
      {:ex_quality, "~> 0.15", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
      # Test-only: a host brings its own database driver, and this package
      # needs one only to test itself (the rule sp-ADR-0005 records for
      # statifier_persistence).
      {:postgrex, "~> 0.22", only: :test}
    ]
  end
end
