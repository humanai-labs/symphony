defmodule SymphonyElixir.Claude.StreamParser do
  @moduledoc """
  Pure mapping from a single decoded `claude -p --output-format stream-json` object
  to a Symphony runner event `{event_atom, details_map}`. Field names follow the
  fixtures recorded in test/fixtures/claude/.
  """

  @spec classify(map()) :: {atom(), map()}
  def classify(%{"type" => "system", "subtype" => "init"} = line),
    do: {:session_started, %{session_id: line["session_id"]}}

  # Pass/fail is driven by is_error (see test/fixtures/claude/SHAPES.md), not subtype strings.
  def classify(%{"type" => "result", "is_error" => true} = line),
    do: {:turn_failed, %{session_id: line["session_id"], usage: usage(line["usage"])}}

  def classify(%{"type" => "result"} = line),
    do: {:turn_completed, %{session_id: line["session_id"], usage: usage(line["usage"])}}

  def classify(%{"type" => "error"} = line), do: {:codex_error, %{details: line}}
  def classify(%{"type" => "assistant"} = line), do: {:notification, %{payload: line}}
  def classify(%{"type" => "user"} = line), do: {:notification, %{payload: line}}
  def classify(line), do: {:notification, %{payload: line}}

  defp usage(%{} = usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0
    %{input_tokens: input, output_tokens: output, total_tokens: input + output}
  end

  defp usage(_), do: nil
end
