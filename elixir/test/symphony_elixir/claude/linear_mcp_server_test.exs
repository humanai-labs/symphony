defmodule SymphonyElixir.Claude.LinearMcpServerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.LinearMcpServer, as: Server

  test "initialize returns protocol + serverInfo" do
    resp = Server.handle_request(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}}, %{})
    assert resp["id"] == 1
    assert get_in(resp, ["result", "serverInfo", "name"]) == "symphony-linear"
  end

  test "tools/list advertises linear_graphql" do
    resp = Server.handle_request(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}, %{})
    names = resp["result"]["tools"] |> Enum.map(& &1["name"])
    assert "linear_graphql" in names
  end

  test "tools/call runs linear_graphql via injected client and returns MCP content" do
    deps = %{graphql: fn _q, _v -> {:ok, %{"data" => %{"viewer" => %{"id" => "u1"}}}} end}

    resp =
      Server.handle_request(
        %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/call", "params" => %{"name" => "linear_graphql", "arguments" => %{"query" => "query { viewer { id } }"}}},
        deps
      )

    assert resp["result"]["isError"] == false
    assert [%{"type" => "text", "text" => text}] = resp["result"]["content"]
    assert text =~ "u1"
  end

  test "tools/call surfaces client errors as isError" do
    deps = %{graphql: fn _q, _v -> {:error, :boom} end}
    resp = Server.handle_request(%{"jsonrpc" => "2.0", "id" => 4, "method" => "tools/call", "params" => %{"name" => "linear_graphql", "arguments" => %{"query" => "q"}}}, deps)
    assert resp["result"]["isError"] == true
  end
end
