defmodule StatifierRouter.MixProject do
  use Mix.Project

  @version "0.3.0"
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

  defp docs do
    [
      name: "StatifierRouter",
      source_ref: "v#{@version}",
      canonical: "https://hexdocs.pm/statifier_router",
      source_url: @source_url,
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
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
      {:ex_quality, "~> 0.14", only: [:dev, :test], runtime: false},
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
