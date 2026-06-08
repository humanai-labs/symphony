defmodule SymphonyElixir.Claude.CliRunner do
  @moduledoc """
  Runs a Linear issue turn with Claude Code over `claude -p --output-format stream-json`.
  Unlike Codex app-server (long-lived thread), each turn is a one-shot process resumed
  via `--resume <session_id>`; the resume id lives in a small Agent inside the session.

  Stall detection (a turn going quiet for too long) is handled by the Orchestrator via
  the per-runner `claude.stall_timeout_ms` (Phase 7), NOT inside this runner — the
  runner's `turn_timeout_ms` is a per-message receive timeout, same as `Codex.AppServer`.
  """

  @behaviour SymphonyElixir.Runner

  require Logger
  alias SymphonyElixir.{Claude.StreamParser, Config, PathSafety, SSH}

  @type session :: %{workspace: Path.t(), worker_host: String.t() | nil, resume: pid()}

  @port_line_bytes 1_048_576

  @impl true
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, resume} <- Agent.start_link(fn -> nil end) do
      {:ok, %{workspace: expanded, worker_host: worker_host, resume: resume}}
    end
  end

  @impl true
  def run_turn(%{workspace: workspace, worker_host: worker_host, resume: resume}, prompt, _issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    resume_id = Agent.get(resume, & &1)

    with {:ok, port} <- start_port(workspace, worker_host, prompt, resume_id) do
      try do
        receive_loop(port, on_message, resume, Config.settings!().claude.turn_timeout_ms, "")
      after
        close_port(port)
      end
    end
  end

  @impl true
  def stop_session(%{resume: resume}) do
    if Process.alive?(resume), do: Agent.stop(resume)
    :ok
  end

  # run/4 convenience mirrors AppServer.run/4 for tests.
  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  defp start_port(workspace, nil, prompt, resume_id) do
    bash = System.find_executable("bash")

    if is_nil(bash) do
      {:error, :bash_not_found}
    else
      {:ok,
       Port.open({:spawn_executable, String.to_charlist(bash)}, [
         :binary,
         :exit_status,
         :stderr_to_stdout,
         line: @port_line_bytes,
         cd: String.to_charlist(workspace),
         args: [~c"-lc", String.to_charlist(command_string(prompt, resume_id))]
       ])}
    end
  end

  defp start_port(workspace, worker_host, prompt, resume_id) when is_binary(worker_host) do
    remote = "cd #{shell_escape(workspace)} && exec #{command_string(prompt, resume_id)}"
    SSH.start_port(worker_host, remote, line: @port_line_bytes)
  end

  defp command_string(prompt, resume_id) do
    claude = Config.settings!().claude
    resume_flag = if is_binary(resume_id), do: " --resume #{shell_escape(resume_id)}", else: ""
    tools = Enum.join(claude.allowed_tools, ",")

    # `< /dev/null` is REQUIRED: claude -p otherwise waits ~3s for stdin before proceeding
    # (the prompt is passed as argv, not stdin). See test/fixtures/claude/SHAPES.md.
    "#{claude.command} -p --output-format stream-json --verbose" <>
      " --permission-mode #{shell_escape(claude.permission_mode)}" <>
      " --allowedTools #{shell_escape(tools)}" <>
      resume_flag <>
      " " <> shell_escape(prompt) <> " < /dev/null"
  end

  defp receive_loop(port, on_message, resume, timeout_ms, pending) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        handle_line(port, on_message, resume, timeout_ms, pending <> to_string(chunk))

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, on_message, resume, timeout_ms, pending <> to_string(chunk))

      # A clean exit (0) without a prior `result` line is the distinct
      # `:turn_ended_without_result` anomaly (claude exited but never emitted a result).
      {^port, {:exit_status, 0}} ->
        {:error, :turn_ended_without_result}

      # A non-zero exit is the separate `:port_exit` failure (the process itself crashed).
      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms -> {:error, :turn_timeout}
    end
  end

  defp handle_line(port, on_message, resume, timeout_ms, line) do
    case Jason.decode(line) do
      {:ok, decoded} ->
        {event, details} = StreamParser.classify(decoded)

        if event == :session_started and is_binary(details[:session_id]),
          do: Agent.update(resume, fn _ -> details[:session_id] end)

        emit(on_message, event, details)

        case event do
          :turn_completed -> {:ok, %{session_id: details[:session_id], result: :turn_completed}}
          :turn_failed -> {:error, {:turn_failed, details}}
          :codex_error -> {:error, {:codex_error, details}}
          _ -> receive_loop(port, on_message, resume, timeout_ms, "")
        end

      {:error, _} ->
        Logger.debug("Claude non-JSON line: #{String.slice(line, 0, 200)}")
        receive_loop(port, on_message, resume, timeout_ms, "")
    end
  end

  defp emit(on_message, event, details) do
    on_message.(Map.merge(details, %{event: event, timestamp: DateTime.utc_now()}))
  end

  # Reuse the same cwd safety contract as Codex.AppServer.
  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp close_port(port) do
    if is_port(port) and :erlang.port_info(port) != :undefined do
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp shell_escape(value) when is_binary(value),
    do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
