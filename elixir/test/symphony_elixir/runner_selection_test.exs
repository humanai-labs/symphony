defmodule SymphonyElixir.RunnerSelectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RunnerSelection

  test "agent:claude routes to claude" do
    assert RunnerSelection.from_labels(["agent:claude", "backend"], :codex) == {:ok, :claude}
  end

  test "agent:codex routes to codex" do
    assert RunnerSelection.from_labels(["Agent:Codex"], :claude) == {:ok, :codex}
  end

  test "no agent label uses the default" do
    assert RunnerSelection.from_labels(["backend"], :codex) == {:ok, :codex}
    assert RunnerSelection.from_labels([], :claude) == {:ok, :claude}
  end

  test "both agent labels are a conflict, never a guess" do
    assert RunnerSelection.from_labels(["agent:claude", "agent:codex"], :codex) ==
             {:error, :conflicting_labels}
  end

  test "label matching is case and whitespace insensitive" do
    assert RunnerSelection.from_labels([" Agent:Claude "], :codex) == {:ok, :claude}
  end
end
