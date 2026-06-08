defmodule SymphonyElixir.RunnerSelection do
  @moduledoc """
  Deterministic label -> runner routing. A Linear `agent:*` label is the
  execution-ownership contract, never a hint. Both labels present is a conflict.
  """

  @claude_label "agent:claude"
  @codex_label "agent:codex"

  @spec from_labels([String.t()], :codex | :claude) ::
          {:ok, :codex | :claude} | {:error, :conflicting_labels}
  def from_labels(labels, default) when is_list(labels) and default in [:codex, :claude] do
    normalized = MapSet.new(labels, &normalize/1)
    claude? = MapSet.member?(normalized, @claude_label)
    codex? = MapSet.member?(normalized, @codex_label)

    cond do
      claude? and codex? -> {:error, :conflicting_labels}
      claude? -> {:ok, :claude}
      codex? -> {:ok, :codex}
      true -> {:ok, default}
    end
  end

  defp normalize(label) when is_binary(label), do: label |> String.trim() |> String.downcase()
  defp normalize(_label), do: ""
end
