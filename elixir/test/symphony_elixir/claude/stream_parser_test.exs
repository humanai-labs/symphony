defmodule SymphonyElixir.Claude.StreamParserTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.StreamParser

  test "system/init yields session_started with session id" do
    line = %{"type" => "system", "subtype" => "init", "session_id" => "sess-1"}
    assert {:session_started, %{session_id: "sess-1"}} = StreamParser.classify(line)
  end

  test "successful result yields turn_completed with usage and session id" do
    line = %{
      "type" => "result",
      "subtype" => "success",
      "session_id" => "sess-1",
      "usage" => %{"input_tokens" => 12, "output_tokens" => 34}
    }

    assert {:turn_completed, %{session_id: "sess-1", usage: %{input_tokens: 12, output_tokens: 34, total_tokens: 46}}} =
             StreamParser.classify(line)
  end

  test "result with is_error: true yields turn_failed (the real failure signal)" do
    line = %{"type" => "result", "subtype" => "error_max_turns", "is_error" => true, "session_id" => "sess-1"}
    assert {:turn_failed, %{session_id: "sess-1"}} = StreamParser.classify(line)
  end

  test "result with is_error: false yields turn_completed regardless of subtype" do
    line = %{"type" => "result", "subtype" => "success", "is_error" => false, "session_id" => "sess-1"}
    assert {:turn_completed, %{session_id: "sess-1"}} = StreamParser.classify(line)
  end

  test "assistant message is a notification" do
    assert {:notification, %{}} = StreamParser.classify(%{"type" => "assistant", "message" => %{}})
  end

  test "explicit error type yields codex_error" do
    assert {:codex_error, %{}} = StreamParser.classify(%{"type" => "error", "error" => %{"message" => "boom"}})
  end
end
