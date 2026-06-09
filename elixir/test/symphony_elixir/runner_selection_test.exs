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

  test "non-binary labels are ignored and the default applies" do
    assert RunnerSelection.from_labels([nil, :backend, 42], :claude) == {:ok, :claude}
  end

  test "require_explicit refuses the default when no agent label is present" do
    assert RunnerSelection.from_labels(["backend"], :codex, require_explicit: true) ==
             {:error, :no_runner_specified}

    assert RunnerSelection.from_labels([], :claude, require_explicit: true) ==
             {:error, :no_runner_specified}
  end

  test "require_explicit still honours an explicit agent label" do
    assert RunnerSelection.from_labels(["agent:claude"], :codex, require_explicit: true) ==
             {:ok, :claude}

    assert RunnerSelection.from_labels(["agent:codex"], :claude, require_explicit: true) ==
             {:ok, :codex}
  end

  test "require_explicit never masks a conflict" do
    assert RunnerSelection.from_labels(["agent:codex", "agent:claude"], :codex, require_explicit: true) ==
             {:error, :conflicting_labels}
  end

  test "require_explicit: false is the default and routes to the default runner" do
    assert RunnerSelection.from_labels(["backend"], :codex, require_explicit: false) == {:ok, :codex}
  end
end
