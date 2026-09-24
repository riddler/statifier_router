defmodule StatifierRouter.GateConfigTest do
  @moduledoc """
  The gate imports the "Isolated tests" stage's cover data only where
  coverage is measured.

  The Tests stage of `mix quality` hands its `test: [args: ...]` to
  `mix coveralls` on the full gate and to plain `mix test` on `--quick`
  and on a `--test-scope` run. An excoveralls switch there fails those
  two runs with an unknown option, so the import is the `coveralls`
  alias in `mix.exs`, which reaches only the command that measures.

  ## What it does not catch

    * Whether the full gate's floor really counts the isolated modules:
      that is a figure, read off a full `mix quality` run.
    * An excoveralls switch other than the ones named in `@coveralls_only`.
  """
  use ExUnit.Case, async: true

  # Switches `mix coveralls` accepts and `mix test` refuses.
  @coveralls_only ~w(--import-cover --filter --umbrella --parallel --sort
                     --output-dir --subdir --rootdir --flagname)

  defp quality_config do
    {config, _binding} = Code.eval_file(".quality.exs")
    config
  end

  defp test_args(config), do: config |> Keyword.get(:test, []) |> Keyword.get(:args, [])

  test "the Tests stage args carry no excoveralls-only switch, in any profile" do
    config = quality_config()

    profiles =
      for {_name, profile} <- Keyword.get(config, :profiles, []), do: test_args(profile)

    for args <- [test_args(config) | profiles], arg <- args do
      refute arg in @coveralls_only,
             "#{arg} in .quality.exs test args reaches plain `mix test` on --quick"
    end
  end

  test "mix coveralls imports the isolated stage's export from cover/" do
    aliases = Mix.Project.config() |> Keyword.get(:aliases, []) |> Keyword.get(:coveralls, [])

    assert ["coveralls --import-cover cover"] = aliases

    [isolated] =
      for stage <- Keyword.get(quality_config(), :custom, []), stage[:key] == :isolated, do: stage

    assert ["--export-coverage", "isolated"] = Enum.take(isolated[:args], -2)
  end
end
