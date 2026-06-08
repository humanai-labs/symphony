defmodule SymphonyElixir.RunnerFailurePolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RunnerFailurePolicy, as: Policy

  test "default: retry same runner under budget, block at budget" do
    assert Policy.on_runtime_failure(1, 3, []) == :retry_same
    assert Policy.on_runtime_failure(2, 3, []) == :retry_same
    assert Policy.on_runtime_failure(3, 3, []) == :block
  end

  test "fallback disabled never switches even at budget" do
    assert Policy.on_runtime_failure(3, 3, fallback_enabled: false, current: :claude) == :block
  end

  test "fallback enabled switches to the other runner at budget, then blocks when both exhausted" do
    assert Policy.on_runtime_failure(3, 3,
             fallback_enabled: true,
             current: :claude,
             exhausted: MapSet.new()
           ) ==
             {:switch, :codex}

    assert Policy.on_runtime_failure(3, 3,
             fallback_enabled: true,
             current: :codex,
             exhausted: MapSet.new([:claude])
           ) ==
             :block
  end
end
