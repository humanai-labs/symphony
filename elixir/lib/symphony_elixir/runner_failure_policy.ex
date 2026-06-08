defmodule SymphonyElixir.RunnerFailurePolicy do
  @moduledoc """
  Pure decision for a runtime failure: retry the same runner, switch (opt-in only),
  or block. Default path never switches models. `failure_count` is the count AFTER
  incrementing for the current failure.
  """

  @spec on_runtime_failure(non_neg_integer(), pos_integer(), keyword()) ::
          :retry_same | :block | {:switch, :codex | :claude}
  def on_runtime_failure(failure_count, budget, opts)
      when is_integer(failure_count) and is_integer(budget) and budget > 0 do
    cond do
      failure_count < budget -> :retry_same
      Keyword.get(opts, :fallback_enabled, false) -> switch_or_block(opts)
      true -> :block
    end
  end

  defp switch_or_block(opts) do
    current = Keyword.fetch!(opts, :current)
    exhausted = Keyword.get(opts, :exhausted, MapSet.new()) |> MapSet.put(current)
    other = other_runner(current)

    if MapSet.member?(exhausted, other), do: :block, else: {:switch, other}
  end

  defp other_runner(:codex), do: :claude
  defp other_runner(:claude), do: :codex
end
