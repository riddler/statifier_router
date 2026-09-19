defmodule StatifierRouterTest do
  use ExUnit.Case, async: true

  doctest StatifierRouter

  # sabotage: version/0 returning the literal "9.9.9" instead of @version
  # turned this test red; restored, green.
  test "version/0 returns the version mix.exs declares" do
    assert StatifierRouter.version() == Mix.Project.config()[:version]
  end
end
