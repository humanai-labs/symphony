defmodule SymphonyElixir.RunnerSelection do
  @moduledoc """
  Deterministic label -> runner routing. A Linear `agent:*` label is the
  execution-ownership contract, never a hint. Both labels present is a conflict.

  With `require_explicit: true`, an issue carrying no `agent:*` label is not
  routed to the default runner but reported as `{:error, :no_runner_specified}`
  so the caller can refuse to start work until a runner is chosen.
  """

  @claude_label "agent:claude"
  @codex_label "agent:codex"

  @spec from_labels([String.t()], :codex | :claude, keyword()) ::
          {:ok, :codex | :claude} | {:error, :conflicting_labels | :no_runner_specified}
  def from_labels(labels, default, opts \\ [])
      when is_list(labels) and default in [:codex, :claude] and is_list(opts) do
    normalized = MapSet.new(labels, &normalize/1)
    claude? = MapSet.member?(normalized, @claude_label)
    codex? = MapSet.member?(normalized, @codex_label)

    cond do
      claude? and codex? -> {:error, :conflicting_labels}
      claude? -> {:ok, :claude}
      codex? -> {:ok, :codex}
      Keyword.get(opts, :require_explicit, false) -> {:error, :no_runner_specified}
      true -> {:ok, default}
    end
  end

  defp normalize(label) when is_binary(label), do: label |> String.trim() |> String.downcase()
  defp normalize(_label), do: ""
end
