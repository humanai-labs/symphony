defmodule SymphonyElixir.RunnerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Runner

  test "module_for maps runner atoms to runner modules" do
    assert Runner.module_for(:codex) == SymphonyElixir.Codex.AppServer
    assert Runner.module_for(:claude) == SymphonyElixir.Claude.CliRunner
  end

  test "module_for raises on unknown runner" do
    assert_raise ArgumentError, fn -> Runner.module_for(:bogus) end
  end
end
