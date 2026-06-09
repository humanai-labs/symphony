defmodule SymphonyElixir.Claude.CliRunnerTest do
  use SymphonyElixir.TestSupport

  import Bitwise

  alias SymphonyElixir.Claude.CliRunner

  test "start_session writes a 0600 mcp-config with injected Linear auth, stop_session removes it" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-claude-mcp-session-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CL-SESS")
      mcp_binary = Path.join(test_root, "symphony_linear_mcp")
      File.mkdir_p!(workspace)
      File.write!(mcp_binary, "#!/bin/sh\n")
      File.chmod!(mcp_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_api_token: "test-api-key",
        claude_mcp_server_path: mcp_binary
      )

      assert {:ok, session} = CliRunner.start_session(workspace)
      path = session.mcp_config_path
      assert is_binary(path)
      assert File.exists?(path)

      # secret: owner-only permissions
      assert (File.stat!(path).mode &&& 0o777) == 0o600

      config = path |> File.read!() |> Jason.decode!()
      assert get_in(config, ["mcpServers", "symphony-linear", "env", "LINEAR_API_KEY"]) == "test-api-key"
      assert get_in(config, ["mcpServers", "symphony-linear", "command"]) == mcp_binary

      CliRunner.stop_session(session)
      refute File.exists?(path)
    after
      File.rm_rf(test_root)
    end
  end

  test "start_session leaves mcp_config_path nil when no mcp_server_path is configured" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-claude-no-mcp-session-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CL-NO-SESS")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, session} = CliRunner.start_session(workspace)
      assert session.mcp_config_path == nil

      # stop_session must tolerate a nil config path
      assert CliRunner.stop_session(session) == :ok
    after
      File.rm_rf(test_root)
    end
  end

  test "cli runner runs one turn and emits session_started + turn_completed" do
    test_root = Path.join(System.tmp_dir!(), "symphony-claude-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CL1")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-cl1"}'
      printf '%s\\n' '{"type":"assistant","message":{"role":"assistant"}}'
      printf '%s\\n' '{"type":"result","subtype":"success","session_id":"sess-cl1","usage":{"input_tokens":5,"output_tokens":7}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-cl1",
        identifier: "MT-CL1",
        title: "Claude turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-CL1",
        labels: ["agent:claude"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:claude_message, message}) end

      assert {:ok, result} = CliRunner.run(workspace, "do the thing", issue, on_message: on_message)
      assert result.session_id == "sess-cl1"

      assert_received {:claude_message, %{event: :session_started, session_id: "sess-cl1", timestamp: %DateTime{}}}
      assert_received {:claude_message, %{event: :turn_completed, usage: %{total_tokens: 12}}}
    after
      File.rm_rf(test_root)
    end
  end

  test "cli runner returns turn_failed when is_error is true" do
    test_root = Path.join(System.tmp_dir!(), "symphony-claude-fail-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CL-FAIL")
      claude_binary = Path.join(test_root, "fake-claude-fail")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-x"}'
      printf '%s\\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"sess-x","usage":{"input_tokens":1,"output_tokens":0}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-cl-fail",
        identifier: "MT-CL-FAIL",
        title: "Claude fail",
        state: "In Progress",
        url: "https://example.org/issues/MT-CL-FAIL",
        labels: ["agent:claude"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:claude_message, message}) end

      assert {:error, {:turn_failed, _}} = CliRunner.run(workspace, "do the thing", issue, on_message: on_message)

      assert_received {:claude_message, %{event: :turn_failed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "command includes --mcp-config when mcp_server_path is set" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-claude-mcp-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CL-MCP")
      claude_binary = Path.join(test_root, "fake-claude-mcp")
      mcp_binary = Path.join(test_root, "symphony_linear_mcp")
      trace = Path.join(test_root, "argv-mcp.trace")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      printf 'ARGV:%s\\n' "$*" >> "#{trace}"
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-mcp"}'
      printf '%s\\n' '{"type":"result","subtype":"success","session_id":"sess-mcp","usage":{"input_tokens":1,"output_tokens":1}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)
      # mcp binary just needs to exist (path is injected into config, not executed in test)
      File.write!(mcp_binary, "#!/bin/sh\n")
      File.chmod!(mcp_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary,
        claude_mcp_server_path: mcp_binary
      )

      issue = %Issue{
        id: "issue-cl-mcp",
        identifier: "MT-CL-MCP",
        title: "MCP config test",
        state: "In Progress",
        url: "https://example.org/issues/MT-CL-MCP",
        labels: ["agent:claude"]
      }

      assert {:ok, _result} = CliRunner.run(workspace, "do mcp thing", issue)

      argv_line = File.read!(trace) |> String.split("\n", trim: true) |> List.first()
      assert argv_line =~ "--mcp-config"

      # Regression guard: the prompt must precede the variadic flags, otherwise
      # claude swallows it as an extra --allowedTools/--mcp-config value and aborts
      # with "Invalid MCP configuration" (port exit 1).
      {prompt_pos, _} = :binary.match(argv_line, "do mcp thing")
      {tools_pos, _} = :binary.match(argv_line, "--allowedTools")
      {mcp_pos, _} = :binary.match(argv_line, "--mcp-config")
      assert prompt_pos < tools_pos
      assert prompt_pos < mcp_pos
    after
      File.rm_rf(test_root)
    end
  end

  test "command does NOT include --mcp-config when mcp_server_path is nil" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-claude-no-mcp-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CL-NO-MCP")
      claude_binary = Path.join(test_root, "fake-claude-no-mcp")
      trace = Path.join(test_root, "argv-no-mcp.trace")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      printf 'ARGV:%s\\n' "$*" >> "#{trace}"
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-no-mcp"}'
      printf '%s\\n' '{"type":"result","subtype":"success","session_id":"sess-no-mcp","usage":{"input_tokens":1,"output_tokens":1}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      # default: claude_mcp_server_path is nil
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-cl-no-mcp",
        identifier: "MT-CL-NO-MCP",
        title: "No MCP config",
        state: "In Progress",
        url: "https://example.org/issues/MT-CL-NO-MCP",
        labels: ["agent:claude"]
      }

      assert {:ok, _result} = CliRunner.run(workspace, "do thing", issue)

      argv_line = File.read!(trace) |> String.split("\n", trim: true) |> List.first()
      refute argv_line =~ "--mcp-config"
    after
      File.rm_rf(test_root)
    end
  end

  test "second turn resumes the captured session id" do
    test_root = Path.join(System.tmp_dir!(), "symphony-claude-resume-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CL2")
      claude_binary = Path.join(test_root, "fake-claude")
      trace = Path.join(test_root, "argv.trace")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      printf 'ARGV:%s\\n' "$*" >> "#{trace}"
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-cl2"}'
      printf '%s\\n' '{"type":"result","subtype":"success","session_id":"sess-cl2","usage":{"input_tokens":1,"output_tokens":1}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root, claude_command: claude_binary)

      issue = %Issue{
        id: "issue-cl2",
        identifier: "MT-CL2",
        title: "Resume",
        state: "In Progress",
        url: "https://example.org/MT-CL2",
        labels: ["agent:claude"]
      }

      assert {:ok, session} = CliRunner.start_session(workspace)
      assert {:ok, _} = CliRunner.run_turn(session, "turn 1", issue)
      assert {:ok, _} = CliRunner.run_turn(session, "turn 2", issue)
      CliRunner.stop_session(session)

      [first, second] = File.read!(trace) |> String.split("\n", trim: true)
      refute first =~ "--resume"
      assert second =~ "--resume sess-cl2"
    after
      File.rm_rf(test_root)
    end
  end
end
