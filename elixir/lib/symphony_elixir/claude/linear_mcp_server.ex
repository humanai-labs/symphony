defmodule SymphonyElixir.Claude.LinearMcpServer do
  @moduledoc """
  Minimal stdio MCP server exposing Linear writes to Claude, reusing Linear.Client.
  Spawned by `claude --mcp-config`. `main/1` runs the stdio loop; `handle_request/2`
  is pure and unit-tested. Response envelopes follow test/fixtures/claude/MCP.md.
  """

  @tool_name "linear_graphql"

  @spec main([String.t()]) :: no_return()
  def main(_argv) do
    # Escript runtime: bundled apps are NOT auto-started. Req needs its deps up before
    # any HTTP call. (initialize / tools/list need no HTTP; tools/call does.)
    {:ok, _} = Application.ensure_all_started(:req)
    deps = %{graphql: &default_graphql/2}
    loop(deps)
  end

  defp loop(deps) do
    case IO.gets("") do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        case Jason.decode(String.trim(line)) do
          {:ok, request} ->
            request |> handle_request(deps) |> respond()

          {:error, _} ->
            :ok
        end

        loop(deps)
    end
  end

  defp respond(nil), do: :ok
  defp respond(response), do: IO.puts(Jason.encode!(response))

  @spec handle_request(map(), map()) :: map() | nil
  def handle_request(%{"method" => "initialize", "id" => id}, _deps) do
    result(id, %{
      "protocolVersion" => "2024-11-05",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "symphony-linear", "version" => "0.1.0"}
    })
  end

  def handle_request(%{"method" => "tools/list", "id" => id}, _deps) do
    result(id, %{
      "tools" => [
        %{
          "name" => @tool_name,
          "description" => "Run a raw GraphQL query/mutation against Linear with Symphony auth.",
          "inputSchema" => %{
            "type" => "object",
            "required" => ["query"],
            "properties" => %{
              "query" => %{"type" => "string"},
              "variables" => %{"type" => "object"}
            }
          }
        }
      ]
    })
  end

  def handle_request(
        %{
          "method" => "tools/call",
          "id" => id,
          "params" => %{"name" => @tool_name, "arguments" => args}
        },
        deps
      ) do
    graphql = Map.get(deps, :graphql, &default_graphql/2)
    query = args["query"] || ""
    variables = args["variables"] || %{}

    case graphql.(query, variables) do
      {:ok, response} -> result(id, content(Jason.encode!(response), false))
      {:error, reason} -> result(id, content("Linear error: #{inspect(reason)}", true))
    end
  end

  def handle_request(%{"method" => "notifications/" <> _}, _deps), do: nil
  def handle_request(%{"id" => id}, _deps), do: result(id, content("Unsupported method", true))
  def handle_request(_other, _deps), do: nil

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp content(text, is_error?),
    do: %{"content" => [%{"type" => "text", "text" => text}], "isError" => is_error?}

  # IMPORTANT: this runs as a standalone escript spawned by `claude` inside the issue
  # workspace — there is NO Symphony WORKFLOW.md there, so we must NOT use
  # Config.settings!()/Linear.Client (which read tracker.api_key/endpoint from config).
  # Auth comes from env injected by CliRunner via the --mcp-config `env` block.
  defp default_graphql(query, variables) do
    api_key = System.get_env("LINEAR_API_KEY")
    endpoint = System.get_env("LINEAR_ENDPOINT") || "https://api.linear.app/graphql"

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_linear_api_token}
    else
      case Req.post(endpoint,
             headers: [{"Authorization", api_key}, {"Content-Type", "application/json"}],
             json: %{"query" => query, "variables" => variables},
             connect_options: [timeout: 30_000]
           ) do
        {:ok, %{status: 200, body: body}} -> {:ok, body}
        {:ok, %{status: status}} -> {:error, {:linear_api_status, status}}
        {:error, reason} -> {:error, {:linear_api_request, reason}}
      end
    end
  end
end
