# Symphony Runner Abstraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a Linear `agent:codex` / `agent:claude` label the full-lifecycle execution-ownership contract for an issue, add a Claude Code runner alongside the existing Codex runner, and Block (never silently switch models) when a runner exhausts its failure budget.

**Architecture:** Introduce a `SymphonyElixir.Runner` behaviour (`start_session/2`, `run_turn/4`, `stop_session/1`) that the existing `Codex.AppServer` already satisfies and a new `Claude.CliRunner` implements. `AgentRunner` picks the runner module from the issue's label; the `Orchestrator` persists the chosen runner + a per-runner failure counter through its existing retry machinery and Blocks on budget exhaustion. Claude writes to Linear through a stdio MCP escript that reuses `Linear.Client`. Cross-runner fallback is opt-in and off by default.

**Tech Stack:** Elixir, Ecto (config schema), Jason, ExUnit. Runners are stdio/JSON line protocols driven over Erlang ports (Codex app-server JSON-RPC; Claude `claude -p --output-format stream-json`).

**Reference spec:** `docs/superpowers/specs/2026-06-08-symphony-runner-abstraction-design.md`

---

## Conventions used by every task

- Run a single test file: `cd elixir && mix test test/symphony_elixir/<file>.exs`
- Run one test by line: `cd elixir && mix test test/symphony_elixir/<file>.exs:<line>`
- Full suite: `cd elixir && mix test`
- Format gate: `cd elixir && mix format` before every commit.
- All new test modules start with `use SymphonyElixir.TestSupport` (brings in `Issue`, `Workflow`, `AppServer`, `capture_log`, `write_workflow_file!`, and a `setup` that writes a temp `WORKFLOW.md`).
- Work happens on the existing `feat/runner-abstraction` branch.

## Canonical interfaces (referenced by many tasks — keep names identical)

```elixir
# SymphonyElixir.Runner (behaviour)
@callback start_session(workspace :: Path.t(), opts :: keyword()) :: {:ok, session :: term()} | {:error, term()}
@callback run_turn(session :: term(), prompt :: String.t(), issue :: map(), opts :: keyword()) :: {:ok, map()} | {:error, term()}
@callback stop_session(session :: term()) :: :ok
# plus pure helper:
Runner.module_for(:codex) :: SymphonyElixir.Codex.AppServer
Runner.module_for(:claude) :: SymphonyElixir.Claude.CliRunner

# SymphonyElixir.RunnerSelection
from_labels(labels :: [String.t()], default :: :codex | :claude) :: {:ok, :codex | :claude} | {:error, :conflicting_labels}

# SymphonyElixir.RunnerFailurePolicy
on_runtime_failure(failure_count :: non_neg_integer(), budget :: pos_integer(), opts :: keyword()) ::
  :retry_same | :block | {:switch, :codex | :claude}
# opts: [fallback_enabled: boolean(), current: :codex | :claude, exhausted: MapSet.t()]
```

The on_message contract every runner must satisfy: it calls `on_message.(update)` where `update` is a **flat top-level map** containing at least `:event` (atom) and `:timestamp` (DateTime), and may contain `:session_id`, `:usage`, `:codex_app_server_pid`. The orchestrator reads all of these at the top level.

---

# Phase 1 — Runner behaviour (pure refactor, Codex regression)

**Outcome:** `AgentRunner` dispatches through a behaviour instead of a hardcoded `alias`. Codex behaviour is byte-for-byte unchanged. Full suite stays green.

### Task 1.1: Define the `Runner` behaviour + `module_for/1`

**Files:**
- Create: `elixir/lib/symphony_elixir/runner.ex`
- Test: `elixir/test/symphony_elixir/runner_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# elixir/test/symphony_elixir/runner_test.exs
defmodule SymphonyElixir.RunnerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Runner

  test "module_for maps runner atoms to runner modules" do
    assert Runner.module_for(:codex) == SymphonyElixir.Codex.AppServer
    assert Runner.module_for(:claude) == SymphonyElixir.Claude.CliRunner
  end

  test "module_for raises on unknown runner" do
    assert_raise ArgumentError, fn -> Runner.module_for(:bogus) end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/runner_test.exs`
Expected: FAIL — `SymphonyElixir.Runner` is undefined.

- [ ] **Step 3: Write the behaviour module**

```elixir
# elixir/lib/symphony_elixir/runner.ex
defmodule SymphonyElixir.Runner do
  @moduledoc """
  Contract every issue runner implements. The orchestrator/AgentRunner only ever
  call these three functions plus `module_for/1`. Implementations: Codex.AppServer,
  Claude.CliRunner.
  """

  @type session :: term()

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}
  @callback run_turn(session(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @spec module_for(:codex | :claude) :: module()
  def module_for(:codex), do: SymphonyElixir.Codex.AppServer
  def module_for(:claude), do: SymphonyElixir.Claude.CliRunner
  def module_for(other), do: raise(ArgumentError, "unknown runner: #{inspect(other)}")
end
```

Note: referencing `SymphonyElixir.Claude.CliRunner` here does not require it to exist yet — it is only an atom until called. It lands in Phase 3.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd elixir && mix test test/symphony_elixir/runner_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
cd elixir && mix format
git add lib/symphony_elixir/runner.ex test/symphony_elixir/runner_test.exs
git commit -m "[runner] Add Runner behaviour and module_for/1"
```

### Task 1.2: Declare `@behaviour` on `Codex.AppServer`

**Files:**
- Modify: `elixir/lib/symphony_elixir/codex/app_server.ex:1-7`

- [ ] **Step 1: Add the behaviour declaration**

In `elixir/lib/symphony_elixir/codex/app_server.ex`, immediately after `require Logger` (line 6), add:

```elixir
  @behaviour SymphonyElixir.Runner
```

`AppServer` already exports `start_session/2`, `run_turn/4`, `stop_session/1` with matching shapes, so no other change is needed.

- [ ] **Step 2: Compile with warnings as errors to verify the callbacks match**

Run: `cd elixir && mix compile --warnings-as-errors`
Expected: compiles clean. If Elixir warns about an unimplemented callback, the signature drifted — fix by matching the behaviour exactly.

- [ ] **Step 3: Run the AppServer suite to confirm no regression**

Run: `cd elixir && mix test test/symphony_elixir/app_server_test.exs`
Expected: PASS (all existing tests).

- [ ] **Step 4: Commit**

```bash
cd elixir && mix format
git add lib/symphony_elixir/codex/app_server.ex
git commit -m "[codex] Declare AppServer as a Runner behaviour"
```

### Task 1.3: Route `AgentRunner` through `Runner.module_for/1`

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex` (alias on line 7; `run/3` on lines 20-35; `run_codex_turns/5` on lines 87-98; `do_run_codex_turns/8` lines 100-139)
- Test: `elixir/test/symphony_elixir/core_test.exs` (add one test near the other AgentRunner tests)

- [ ] **Step 1: Write a failing test that asserts an unknown runner is rejected**

Add to `elixir/test/symphony_elixir/core_test.exs` (inside the existing `describe`-free top level, mirroring sibling tests):

```elixir
  test "agent runner rejects an unknown runner atom" do
    issue = %Issue{
      id: "issue-runner-guard",
      identifier: "MT-RUN",
      title: "Runner guard",
      state: "In Progress",
      url: "https://example.org/issues/MT-RUN",
      labels: []
    }

    assert_raise ArgumentError, fn ->
      AgentRunner.run(issue, nil, runner: :bogus, max_turns: 1)
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/core_test.exs -k "unknown runner"`
Expected: FAIL — `run/3` ignores `:runner` today, so no ArgumentError is raised (it proceeds to workspace creation).

- [ ] **Step 3: Thread the runner module through AgentRunner**

In `elixir/lib/symphony_elixir/agent_runner.ex`:

Replace the alias line 7 (`alias SymphonyElixir.Codex.AppServer`) with:

```elixir
  alias SymphonyElixir.Runner
```

In `run/3` (currently lines 20-35), resolve the module at the top so an invalid runner fails fast:

```elixir
  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    runner = Runner.module_for(Keyword.get(opts, :runner, :codex))

    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} runner=#{inspect(runner)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host, runner) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end
```

Thread `runner` down: change `run_on_worker_host/4` to `run_on_worker_host/5`, `run_codex_turns/5` to take `runner`, and `do_run_codex_turns/8` to call `runner.start_session`, `runner.run_turn`, `runner.stop_session` instead of `AppServer.*`. Concretely, in `run_on_worker_host` (line 37) add `runner` as the last arg and pass it to `run_codex_turns`; in `run_codex_turns` (line 87) replace `AppServer.start_session(...)`/`AppServer.stop_session(...)` with `runner.start_session(...)`/`runner.stop_session(...)`; in `do_run_codex_turns` (line 103) replace `AppServer.run_turn(...)` with `runner.run_turn(...)`. Pass `runner` through each recursive `do_run_codex_turns` call.

- [ ] **Step 4: Run the new test + the full AgentRunner-touching suite**

Run: `cd elixir && mix test test/symphony_elixir/core_test.exs`
Expected: PASS, including the new "unknown runner" test (default `:codex` keeps every other test green).

- [ ] **Step 5: Run the full suite to prove the refactor is behaviour-preserving**

Run: `cd elixir && mix test`
Expected: PASS (no regressions).

- [ ] **Step 6: Commit**

```bash
cd elixir && mix format
git add lib/symphony_elixir/agent_runner.ex test/symphony_elixir/core_test.exs
git commit -m "[runner] Dispatch AgentRunner through the Runner behaviour"
```

---

# Phase 2 — Label routing + Claude config plumbing (no Claude runner yet)

**Outcome:** Labels deterministically select a runner; conflicting labels skip the issue with a Linear comment; the `claude` config block + `agent.default_runner/runner_failure_budget/runner_fallback_enabled` parse from `WORKFLOW.md`. Codex behaviour unchanged.

### Task 2.1: Add config fields — `agent` knobs + `claude` block

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex` (Agent module lines 128-167; new Claude module after Codex module ~line 216; main embedded_schema line 280-290; `changeset/1` lines 393-405)
- Test: `elixir/test/symphony_elixir/workspace_and_config_test.exs`

- [ ] **Step 1: Write failing config tests**

Add to `elixir/test/symphony_elixir/workspace_and_config_test.exs`:

```elixir
  test "agent runner knobs default and parse" do
    assert {:ok, settings} = SymphonyElixir.Config.Schema.parse(%{})
    assert settings.agent.default_runner == "codex"
    assert settings.agent.runner_failure_budget == 3
    assert settings.agent.runner_fallback_enabled == false

    assert {:ok, custom} =
             SymphonyElixir.Config.Schema.parse(%{
               "agent" => %{
                 "default_runner" => "claude",
                 "runner_failure_budget" => 5,
                 "runner_fallback_enabled" => true
               }
             })

    assert custom.agent.default_runner == "claude"
    assert custom.agent.runner_failure_budget == 5
    assert custom.agent.runner_fallback_enabled == true
  end

  test "agent rejects an unknown default_runner" do
    assert {:error, {:invalid_workflow_config, message}} =
             SymphonyElixir.Config.Schema.parse(%{"agent" => %{"default_runner" => "gpt"}})

    assert message =~ "default_runner"
  end

  test "claude block defaults and parses" do
    assert {:ok, settings} = SymphonyElixir.Config.Schema.parse(%{})
    assert settings.claude.command == "claude"
    assert settings.claude.permission_mode == "acceptEdits"
    assert settings.claude.turn_timeout_ms == 1_800_000
    assert settings.claude.stall_timeout_ms == 600_000
    assert is_list(settings.claude.allowed_tools)

    assert {:ok, custom} =
             SymphonyElixir.Config.Schema.parse(%{
               "claude" => %{"command" => "claude-next", "permission_mode" => "plan"}
             })

    assert custom.claude.command == "claude-next"
    assert custom.claude.permission_mode == "plan"
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd elixir && mix test test/symphony_elixir/workspace_and_config_test.exs -k "runner knobs"`
Expected: FAIL — fields/embeds do not exist.

- [ ] **Step 3: Extend the Agent embedded schema**

In `elixir/lib/symphony_elixir/config/schema.ex`, in `defmodule Agent`, add three fields to `embedded_schema` (after line 141):

```elixir
      field(:default_runner, :string, default: "codex")
      field(:runner_failure_budget, :integer, default: 3)
      field(:runner_fallback_enabled, :boolean, default: false)
```

In `Agent.changeset/2`, add the new fields to the `cast` list and validate them. Replace the cast field list and append validations:

```elixir
      |> cast(
        attrs,
        [
          :max_concurrent_agents,
          :max_turns,
          :max_retry_backoff_ms,
          :max_concurrent_agents_by_state,
          :reserved_concurrent_agents_by_state,
          :default_runner,
          :runner_failure_budget,
          :runner_fallback_enabled
        ],
        empty_values: []
      )
      |> validate_inclusion(:default_runner, ["codex", "claude"])
      |> validate_number(:runner_failure_budget, greater_than: 0)
```

(Leave the existing `validate_number`/`update_change`/`validate_*` calls in place after these.)

- [ ] **Step 4: Add the Claude embedded schema**

In `elixir/lib/symphony_elixir/config/schema.ex`, after the `Codex` module ends (after line 216), add:

```elixir
  defmodule Claude do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "claude")
      field(:permission_mode, :string, default: "acceptEdits")

      field(:allowed_tools, {:array, :string},
        default: ["Bash", "Edit", "Write", "Read", "Glob", "Grep"]
      )

      field(:turn_timeout_ms, :integer, default: 1_800_000)
      field(:stall_timeout_ms, :integer, default: 600_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:command, :permission_mode, :allowed_tools, :turn_timeout_ms, :stall_timeout_ms],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end
```

Register the embed in the top-level `embedded_schema` (after line 286 `embeds_one(:codex, ...)`):

```elixir
    embeds_one(:claude, Claude, on_replace: :update, defaults_to_struct: true)
```

And in `changeset/1` (after the `cast_embed(:codex, ...)` on line 401):

```elixir
    |> cast_embed(:claude, with: &Claude.changeset/2)
```

- [ ] **Step 5: Run the config tests**

Run: `cd elixir && mix test test/symphony_elixir/workspace_and_config_test.exs`
Expected: PASS (new + existing).

- [ ] **Step 6: Commit**

```bash
cd elixir && mix format
git add lib/symphony_elixir/config/schema.ex test/symphony_elixir/workspace_and_config_test.exs
git commit -m "[config] Add agent runner knobs and claude config block"
```

### Task 2.2: Extend `test_support.exs` to emit `agent`/`claude` config

**Files:**
- Modify: `elixir/test/support/test_support.exs` (defaults list lines 92-132; section assembly lines 170-209)

- [ ] **Step 1: Add new override defaults**

In `workflow_content/1`'s default keyword list (after line 111 `reserved_concurrent_agents_by_state: %{}`), add:

```elixir
          agent_default_runner: "codex",
          agent_runner_failure_budget: 3,
          agent_runner_fallback_enabled: false,
          claude_command: "claude",
          claude_permission_mode: "acceptEdits",
          claude_allowed_tools: ["Bash", "Edit", "Write", "Read", "Glob", "Grep"],
          claude_turn_timeout_ms: 1_800_000,
          claude_stall_timeout_ms: 600_000,
```

- [ ] **Step 2: Bind and render them**

After line 168 (`prompt = Keyword.get(config, :prompt)`), add bindings:

```elixir
    agent_default_runner = Keyword.get(config, :agent_default_runner)
    agent_runner_failure_budget = Keyword.get(config, :agent_runner_failure_budget)
    agent_runner_fallback_enabled = Keyword.get(config, :agent_runner_fallback_enabled)
    claude_command = Keyword.get(config, :claude_command)
    claude_permission_mode = Keyword.get(config, :claude_permission_mode)
    claude_allowed_tools = Keyword.get(config, :claude_allowed_tools)
    claude_turn_timeout_ms = Keyword.get(config, :claude_turn_timeout_ms)
    claude_stall_timeout_ms = Keyword.get(config, :claude_stall_timeout_ms)
```

In the `sections` list, add three `agent:` lines (after line 192 `reserved_concurrent_agents_by_state` line) and a `claude:` block (after the `codex:` block, before `hooks_yaml`):

```elixir
        "  default_runner: #{yaml_value(agent_default_runner)}",
        "  runner_failure_budget: #{yaml_value(agent_runner_failure_budget)}",
        "  runner_fallback_enabled: #{yaml_value(agent_runner_fallback_enabled)}",
```

```elixir
        "claude:",
        "  command: #{yaml_value(claude_command)}",
        "  permission_mode: #{yaml_value(claude_permission_mode)}",
        "  allowed_tools: #{yaml_value(claude_allowed_tools)}",
        "  turn_timeout_ms: #{yaml_value(claude_turn_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(claude_stall_timeout_ms)}",
```

- [ ] **Step 3: Verify nothing broke (config self-test reads WORKFLOW.md)**

Run: `cd elixir && mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/core_test.exs`
Expected: PASS. (`core_test.exs:91` validates the generated WORKFLOW.md parses completely.)

- [ ] **Step 4: Commit**

```bash
cd elixir && mix format
git add test/support/test_support.exs
git commit -m "[test] Emit agent runner + claude config in test WORKFLOW.md"
```

### Task 2.3: `RunnerSelection` pure module

**Files:**
- Create: `elixir/lib/symphony_elixir/runner_selection.ex`
- Test: `elixir/test/symphony_elixir/runner_selection_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# elixir/test/symphony_elixir/runner_selection_test.exs
defmodule SymphonyElixir.RunnerSelectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RunnerSelection

  test "agent:claude routes to claude" do
    assert RunnerSelection.from_labels(["agent:claude", "backend"], :codex) == {:ok, :claude}
  end

  test "agent:codex routes to codex" do
    assert RunnerSelection.from_labels(["Agent:Codex"], :claude) == {:ok, :codex}
  end

  test "no agent label uses the default" do
    assert RunnerSelection.from_labels(["backend"], :codex) == {:ok, :codex}
    assert RunnerSelection.from_labels([], :claude) == {:ok, :claude}
  end

  test "both agent labels are a conflict, never a guess" do
    assert RunnerSelection.from_labels(["agent:claude", "agent:codex"], :codex) ==
             {:error, :conflicting_labels}
  end

  test "label matching is case and whitespace insensitive" do
    assert RunnerSelection.from_labels([" Agent:Claude "], :codex) == {:ok, :claude}
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd elixir && mix test test/symphony_elixir/runner_selection_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement**

```elixir
# elixir/lib/symphony_elixir/runner_selection.ex
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
```

- [ ] **Step 4: Run to verify pass**

Run: `cd elixir && mix test test/symphony_elixir/runner_selection_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
cd elixir && mix format
git add lib/symphony_elixir/runner_selection.ex test/symphony_elixir/runner_selection_test.exs
git commit -m "[runner] Add deterministic RunnerSelection from labels"
```

### Task 2.4: Orchestrator routes by label, stores runner, skips conflicts

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex` — `do_dispatch_issue/4` (lines 957-968), `spawn_issue_on_worker_host/5` (lines 970-1022; the `AgentRunner.run` call at 971-973 and the running-entry map at 980-1002), `handle_call(:snapshot, ...)` running map (lines 1425-1448)
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`

- [ ] **Step 1: Write a failing test for conflict-skip + runner in snapshot**

Add to `elixir/test/symphony_elixir/orchestrator_status_test.exs` a test that drives dispatch through the test seam. Use the existing memory tracker seam (the file already exercises orchestrator dispatch — mirror its setup). Assert that an issue with both labels is not dispatched and a comment is posted. Concretely add:

```elixir
  test "conflicting agent labels skip dispatch and post a comment" do
    issue = %Issue{
      id: "issue-conflict",
      identifier: "MT-CONFLICT",
      title: "Conflicting labels",
      state: "Todo",
      url: "https://example.org/issues/MT-CONFLICT",
      labels: ["agent:codex", "agent:claude"]
    }

    assert SymphonyElixir.RunnerSelection.from_labels(issue.labels, :codex) ==
             {:error, :conflicting_labels}

    assert SymphonyElixir.Orchestrator.runner_for_dispatch_for_test(issue, :codex) ==
             {:error, :conflicting_labels}
  end
```

> Note: `runner_for_dispatch_for_test/2` is a thin `@doc false` wrapper you add in Step 3 so the routing decision is unit-testable without spinning a real worker. The end-to-end "comment posted" behaviour is verified in Phase 5's live test; here we lock the pure decision.

- [ ] **Step 2: Run to verify failure**

Run: `cd elixir && mix test test/symphony_elixir/orchestrator_status_test.exs -k "conflicting agent labels"`
Expected: FAIL — `runner_for_dispatch_for_test/2` undefined.

- [ ] **Step 3: Implement routing in the orchestrator**

In `elixir/lib/symphony_elixir/orchestrator.ex`:

Add a private resolver + test wrapper near the other `_for_test` helpers (after line 406):

```elixir
  @doc false
  @spec runner_for_dispatch_for_test(Issue.t(), :codex | :claude) ::
          {:ok, :codex | :claude} | {:error, :conflicting_labels}
  def runner_for_dispatch_for_test(%Issue{} = issue, default), do: resolve_runner(issue, default)

  defp resolve_runner(%Issue{labels: labels}, default) when is_list(labels) do
    SymphonyElixir.RunnerSelection.from_labels(labels, default)
  end

  defp resolve_runner(_issue, default), do: {:ok, default}
```

In `do_dispatch_issue/4` (line 957), resolve the runner before selecting a worker host and short-circuit conflicts:

```elixir
  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()
    default_runner = String.to_existing_atom(Config.settings!().agent.default_runner)

    case resolve_runner(issue, default_runner) do
      {:error, :conflicting_labels} ->
        Logger.warning("Skipping dispatch; conflicting agent labels for #{issue_context(issue)}")
        Tracker.create_comment(issue.id, "Conflicting agent labels (agent:codex + agent:claude). Skipped — keep exactly one.")
        release_issue_claim(state, issue.id)

      {:ok, runner} ->
        case select_worker_host(state, preferred_worker_host) do
          :no_worker_capacity ->
            Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
            state

          worker_host ->
            spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, runner)
        end
    end
  end
```

Change `spawn_issue_on_worker_host/5` to `/6` (add `runner`), pass `runner: runner` into `AgentRunner.run`, and store `runner: runner` in the running-entry map:

```elixir
  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, runner) do
    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient, attempt: attempt, worker_host: worker_host, runner: runner)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        issue = mark_dispatch_started(issue, &Tracker.update_issue_state/2)
        # ... existing Logger.info ...
        running =
          Map.put(state.running, issue.id, %{
            # ... all existing fields ...
            runner: runner,
            # ... keep the rest unchanged ...
          })
        # ... unchanged ...
    end
  end
```

Add `runner: metadata[:runner] || :codex` to the snapshot running map in `handle_call(:snapshot, ...)` (within the `Enum.map` starting line 1427) so the dashboard can read it:

```elixir
          runner: Map.get(metadata, :runner, :codex),
```

> `default_runner` is a binary in config; `String.to_existing_atom/1` is safe because `:codex`/`:claude` atoms already exist (defined in `Runner.module_for/1` and `RunnerSelection`). `validate_inclusion` in Task 2.1 guarantees only those two strings reach here.

- [ ] **Step 4: Run the orchestrator suite**

Run: `cd elixir && mix test test/symphony_elixir/orchestrator_status_test.exs`
Expected: PASS (new test + existing — existing issues have no `agent:*` labels so they route to `:codex` exactly as before).

- [ ] **Step 5: Full suite**

Run: `cd elixir && mix test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd elixir && mix format
git add lib/symphony_elixir/orchestrator.ex test/symphony_elixir/orchestrator_status_test.exs
git commit -m "[orchestrator] Route dispatch by label, store runner, skip conflicts"
```

---

# Phase 3 — Claude runner

**Outcome:** `Claude.CliRunner` runs a Claude turn over a port driving `claude -p --output-format stream-json`, emits the shared event vocabulary as flat top-level maps, threads `--resume` across turns, and is covered by fake-binary tests modeled on `app_server_test.exs`.

### Task 3.0 (SPIKE): Capture real `claude` stream-json shapes

**Files:**
- Create: `elixir/test/fixtures/claude/` (fixture files)

- [ ] **Step 1: Record a real one-turn run**

Run (in any throwaway git repo dir):

```bash
mkdir -p elixir/test/fixtures/claude
cd /tmp && rm -rf claude-spike && mkdir claude-spike && cd claude-spike && git init -q
claude -p --output-format stream-json --verbose --permission-mode acceptEdits \
  "Create a file hello.txt containing the word hi, then stop." \
  > /Users/zfc/code/xhs33-symphony-automation/symphony/elixir/test/fixtures/claude/turn_success.jsonl 2>&1 || true
```

- [ ] **Step 2: Inspect and record the exact shapes**

Run: `head -5 elixir/test/fixtures/claude/turn_success.jsonl && tail -2 elixir/test/fixtures/claude/turn_success.jsonl`

Record, in a comment block at the top of `elixir/test/fixtures/claude/SHAPES.md`, the exact JSON keys for: the init/system line (where `session_id` lives), an assistant message line, the final `result` line (its `subtype`, `usage`, `session_id`, `total_cost_usd`). Capture an error/`error_max_turns` variant too if reproducible. **These recorded shapes are the source of truth for Tasks 3.1–3.3.** If a field name below differs from what you recorded, the recorded name wins — update the parser code accordingly.

- [ ] **Step 3: Commit the fixtures**

```bash
git add elixir/test/fixtures/claude/
git commit -m "[claude] Record real stream-json fixtures (spike)"
```

### Task 3.1: `Claude.StreamParser` — map one decoded line to an event

**Files:**
- Create: `elixir/lib/symphony_elixir/claude/stream_parser.ex`
- Test: `elixir/test/symphony_elixir/claude/stream_parser_test.exs`

- [ ] **Step 1: Write failing tests against the recorded shapes**

```elixir
# elixir/test/symphony_elixir/claude/stream_parser_test.exs
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

  test "error result yields turn_failed" do
    line = %{"type" => "result", "subtype" => "error_max_turns", "session_id" => "sess-1"}
    assert {:turn_failed, %{session_id: "sess-1"}} = StreamParser.classify(line)
  end

  test "assistant message is a notification" do
    assert {:notification, %{}} = StreamParser.classify(%{"type" => "assistant", "message" => %{}})
  end

  test "explicit error type yields codex_error" do
    assert {:codex_error, %{}} = StreamParser.classify(%{"type" => "error", "error" => %{"message" => "boom"}})
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd elixir && mix test test/symphony_elixir/claude/stream_parser_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the parser (adjust keys to the spike fixtures)**

```elixir
# elixir/lib/symphony_elixir/claude/stream_parser.ex
defmodule SymphonyElixir.Claude.StreamParser do
  @moduledoc """
  Pure mapping from a single decoded `claude -p --output-format stream-json` object
  to a Symphony runner event `{event_atom, details_map}`. Field names follow the
  fixtures recorded in test/fixtures/claude/.
  """

  @spec classify(map()) :: {atom(), map()}
  def classify(%{"type" => "system", "subtype" => "init"} = line),
    do: {:session_started, %{session_id: line["session_id"]}}

  def classify(%{"type" => "result", "subtype" => "success"} = line),
    do: {:turn_completed, %{session_id: line["session_id"], usage: usage(line["usage"])}}

  def classify(%{"type" => "result", "subtype" => "error" <> _} = line),
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
```

- [ ] **Step 4: Run to verify pass**

Run: `cd elixir && mix test test/symphony_elixir/claude/stream_parser_test.exs`
Expected: PASS. If a key differs from the fixture, fix the code to match the fixture and re-run.

- [ ] **Step 5: Commit**

```bash
cd elixir && mix format
git add lib/symphony_elixir/claude/stream_parser.ex test/symphony_elixir/claude/stream_parser_test.exs
git commit -m "[claude] Add StreamParser event classification"
```

### Task 3.2: `Claude.CliRunner` — local single turn over a port

**Files:**
- Create: `elixir/lib/symphony_elixir/claude/cli_runner.ex`
- Test: `elixir/test/symphony_elixir/claude/cli_runner_test.exs`

- [ ] **Step 1: Write a failing fake-binary test (model: app_server_test.exs)**

```elixir
# elixir/test/symphony_elixir/claude/cli_runner_test.exs
defmodule SymphonyElixir.Claude.CliRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.CliRunner

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
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd elixir && mix test test/symphony_elixir/claude/cli_runner_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement `Claude.CliRunner`**

Implement `@behaviour SymphonyElixir.Runner`. `start_session/2` validates the workspace cwd (reuse the same guard contract as AppServer — call `SymphonyElixir.PathSafety` the same way, or extract a shared `Workspace`/guard helper; simplest: copy AppServer's `validate_workspace_cwd` semantics) and returns a session map holding `workspace`, `worker_host`, and a `resume` Agent (`{:ok, pid} = Agent.start_link(fn -> nil end)`). `run_turn/4` builds the command, opens a port, runs the receive loop classifying lines via `StreamParser`, emits each as a flat top-level map (merge `%{event:, timestamp: DateTime.utc_now()}`), records `session_id` into the resume Agent on `:session_started`, and returns `{:ok, %{session_id: sid, result: :turn_completed}}` on `:turn_completed` / `{:error, {:turn_failed, line}}` on `:turn_failed`. `stop_session/1` stops the Agent.

```elixir
# elixir/lib/symphony_elixir/claude/cli_runner.ex
defmodule SymphonyElixir.Claude.CliRunner do
  @moduledoc """
  Runs a Linear issue turn with Claude Code over `claude -p --output-format stream-json`.
  Unlike Codex app-server (long-lived thread), each turn is a one-shot process resumed
  via `--resume <session_id>`; the resume id lives in a small Agent inside the session.
  """

  @behaviour SymphonyElixir.Runner

  require Logger
  alias SymphonyElixir.{Claude.StreamParser, Config, PathSafety, SSH}

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
  def run_turn(%{workspace: workspace, worker_host: worker_host, resume: resume}, prompt, issue, opts \\ []) do
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
    if is_nil(bash), do: {:error, :bash_not_found}, else:
      {:ok,
       Port.open({:spawn_executable, String.to_charlist(bash)},
         [:binary, :exit_status, :stderr_to_stdout, line: @port_line_bytes,
          cd: String.to_charlist(workspace),
          args: [~c"-lc", String.to_charlist(local_command(prompt, resume_id))]])}
  end

  defp start_port(workspace, worker_host, prompt, resume_id) when is_binary(worker_host) do
    remote = "cd #{shell_escape(workspace)} && exec #{command_string(prompt, resume_id)}"
    SSH.start_port(worker_host, remote, line: @port_line_bytes)
  end

  defp local_command(prompt, resume_id), do: command_string(prompt, resume_id)

  defp command_string(prompt, resume_id) do
    claude = Config.settings!().claude
    resume_flag = if is_binary(resume_id), do: " --resume #{shell_escape(resume_id)}", else: ""
    tools = Enum.join(claude.allowed_tools, ",")

    "#{claude.command} -p --output-format stream-json --verbose" <>
      " --permission-mode #{shell_escape(claude.permission_mode)}" <>
      " --allowedTools #{shell_escape(tools)}" <> resume_flag <>
      " " <> shell_escape(prompt)
  end

  defp receive_loop(port, on_message, resume, timeout_ms, pending) do
    receive do
      {^port, {:data, {:eol, chunk}}} -> handle_line(port, on_message, resume, timeout_ms, pending <> to_string(chunk))
      {^port, {:data, {:noeol, chunk}}} -> receive_loop(port, on_message, resume, timeout_ms, pending <> to_string(chunk))
      {^port, {:exit_status, 0}} -> {:error, :turn_ended_without_result}
      {^port, {:exit_status, status}} -> {:error, {:port_exit, status}}
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
    expanded = Path.expand(workspace)
    root = Path.expand(Config.settings!().workspace.root)

    with {:ok, cw} <- PathSafety.canonicalize(expanded),
         {:ok, cr} <- PathSafety.canonicalize(root) do
      cond do
        cw == cr -> {:error, {:invalid_workspace_cwd, :workspace_root, cw}}
        String.starts_with?(cw <> "/", cr <> "/") -> {:ok, cw}
        true -> {:error, {:invalid_workspace_cwd, :outside_workspace_root, cw, cr}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    if String.trim(workspace) == "" or String.contains?(workspace, ["\n", "\r", <<0>>]),
      do: {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}},
      else: {:ok, workspace}
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

  defp shell_escape(value) when is_binary(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
```

> The cwd guard is duplicated from `AppServer` deliberately to keep this task self-contained. If you prefer DRY, extract `AppServer`'s guard into a shared `SymphonyElixir.WorkspaceCwd` module in a separate refactor commit and call it from both — out of scope for this task.

- [ ] **Step 4: Run to verify pass**

Run: `cd elixir && mix test test/symphony_elixir/claude/cli_runner_test.exs`
Expected: PASS.

- [ ] **Step 5: Add a failure-path test**

Add a second test where the fake binary emits `{"type":"result","subtype":"error_during_execution","session_id":"sess-x"}` and assert `{:error, {:turn_failed, _}}` plus a `{:claude_message, %{event: :turn_failed}}`. Run the file again; expect PASS.

- [ ] **Step 6: Commit**

```bash
cd elixir && mix format
git add lib/symphony_elixir/claude/cli_runner.ex test/symphony_elixir/claude/cli_runner_test.exs
git commit -m "[claude] Add CliRunner local single-turn execution"
```

### Task 3.3: Resume threading across turns

**Files:**
- Test: `elixir/test/symphony_elixir/claude/cli_runner_test.exs` (add a test)
- Modify: `elixir/lib/symphony_elixir/claude/cli_runner.ex` only if the spike shows resume needs flags beyond `--resume`

- [ ] **Step 1: Write a test that the 2nd turn passes `--resume <session_id>`**

Use a fake binary that appends its argv to a trace file (model: the SSH argv-trace test in `app_server_test.exs:1439`). Call `start_session`, then `run_turn` twice on the same session; assert the second invocation's argv contains `--resume sess-cl1` and the first does not.

```elixir
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

      issue = %Issue{id: "issue-cl2", identifier: "MT-CL2", title: "Resume", state: "In Progress", url: "https://example.org/MT-CL2", labels: ["agent:claude"]}

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
```

- [ ] **Step 2: Run — should already pass** (the resume Agent is updated in Task 3.2)

Run: `cd elixir && mix test test/symphony_elixir/claude/cli_runner_test.exs -k "resumes the captured"`
Expected: PASS. If FAIL, fix `command_string/2` to honor `resume_id`.

- [ ] **Step 3: Commit**

```bash
cd elixir && mix format
git add test/symphony_elixir/claude/cli_runner_test.exs
git commit -m "[claude] Test resume session threading across turns"
```

---

# Phase 4 — Claude Linear MCP server (escript)

**Outcome:** Claude can write Workpad/comments/state to Linear through a stdio MCP escript that reuses `Linear.Client`. `CliRunner` generates an `--mcp-config` pointing at it.

### Task 4.0 (SPIKE): Confirm the MCP handshake `claude` expects

- [ ] **Step 1: Read the installed Claude Code MCP docs/help**

Run: `claude --help | grep -A3 mcp` and check `claude mcp --help`. Record in `elixir/test/fixtures/claude/MCP.md`: the exact `--mcp-config` JSON shape (stdio server entry: `{"command":..., "args":[...], "env":{...}}`), and the MCP JSON-RPC methods a stdio server must answer (`initialize`, `tools/list`, `tools/call`) with their exact response envelopes. **These recorded shapes are the source of truth for Tasks 4.1–4.2.**

- [ ] **Step 2: Commit the notes**

```bash
git add elixir/test/fixtures/claude/MCP.md
git commit -m "[claude] Record MCP handshake notes (spike)"
```

### Task 4.1: `Claude.LinearMcpServer` — stdio MCP over Linear.Client

**Files:**
- Create: `elixir/lib/symphony_elixir/claude/linear_mcp_server.ex`
- Test: `elixir/test/symphony_elixir/claude/linear_mcp_server_test.exs`

- [ ] **Step 1: Write failing tests for the pure request handler**

Keep the protocol logic pure and testable: a `handle_request(decoded_json, deps) :: map()` function that does NOT touch stdio. `deps` injects the Linear call (`fn query, vars -> {:ok, map} end`).

```elixir
# elixir/test/symphony_elixir/claude/linear_mcp_server_test.exs
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
        %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/call",
          "params" => %{"name" => "linear_graphql", "arguments" => %{"query" => "query { viewer { id } }"}}},
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
```

- [ ] **Step 2: Run to verify failure**

Run: `cd elixir && mix test test/symphony_elixir/claude/linear_mcp_server_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the server (adjust envelopes to MCP.md from spike)**

```elixir
# elixir/lib/symphony_elixir/claude/linear_mcp_server.ex
defmodule SymphonyElixir.Claude.LinearMcpServer do
  @moduledoc """
  Minimal stdio MCP server exposing Linear writes to Claude, reusing Linear.Client.
  Spawned by `claude --mcp-config`. `main/1` runs the stdio loop; `handle_request/2`
  is pure and unit-tested. Response envelopes follow test/fixtures/claude/MCP.md.
  """

  @tool_name "linear_graphql"

  @spec main([String.t()]) :: no_return()
  def main(_argv) do
    deps = %{graphql: &default_graphql/2}
    loop(deps)
  end

  defp loop(deps) do
    case IO.gets("") do
      :eof -> :ok
      {:error, _} -> :ok
      line ->
        case Jason.decode(String.trim(line)) do
          {:ok, request} ->
            request |> handle_request(deps) |> respond()
          {:error, _} -> :ok
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

  def handle_request(%{"method" => "tools/call", "id" => id, "params" => %{"name" => @tool_name, "arguments" => args}}, deps) do
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
  defp content(text, is_error?), do: %{"content" => [%{"type" => "text", "text" => text}], "isError" => is_error?}

  defp default_graphql(query, variables) do
    SymphonyElixir.Linear.Client.graphql(query, variables, [])
  end
end
```

- [ ] **Step 4: Run to verify pass**

Run: `cd elixir && mix test test/symphony_elixir/claude/linear_mcp_server_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd elixir && mix format
git add lib/symphony_elixir/claude/linear_mcp_server.ex test/symphony_elixir/claude/linear_mcp_server_test.exs
git commit -m "[claude] Add stdio Linear MCP server (pure handler + loop)"
```

### Task 4.2: Build the escript + generate `--mcp-config`

**Files:**
- Modify: `elixir/mix.exs` (add `escript:` to `project/0`)
- Modify: `elixir/lib/symphony_elixir/claude/cli_runner.ex` (`command_string/2` to add `--mcp-config`)
- Test: `elixir/test/symphony_elixir/claude/cli_runner_test.exs`

- [ ] **Step 1: Add escript config to mix.exs**

In `project/0`, add (alongside `test_coverage:` etc.):

```elixir
      escript: [main_module: SymphonyElixir.Claude.LinearMcpServer, name: "symphony_linear_mcp"],
```

- [ ] **Step 2: Build it and confirm the binary exists**

Run: `cd elixir && mix escript.build && ls -l symphony_linear_mcp`
Expected: an executable `symphony_linear_mcp` is produced.

- [ ] **Step 3: Smoke the handshake over stdio**

Run:
```bash
cd elixir && printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ./symphony_linear_mcp
```
Expected: a single JSON line whose `result.serverInfo.name` is `symphony-linear`. (No Linear creds needed for `initialize`.)

- [ ] **Step 4: Write a failing test that CliRunner emits `--mcp-config`**

Extend the resume/argv-trace test (or add one) asserting the argv contains `--mcp-config`. Implement `command_string/2` to write a temp mcp-config JSON (pointing `command` at the built escript path, `env.LINEAR_API_KEY` from `Config`) and append `--mcp-config <path>`. Gate it: only add the flag when the escript path exists, so unit tests with a fake claude binary still pass. Decide the escript path via `Application.app_dir` or a configurable `claude.mcp_server_path` (add as an optional field defaulting to `nil`; when nil, skip `--mcp-config`). The test sets it to a dummy file and asserts the flag appears.

- [ ] **Step 5: Run, format, commit**

Run: `cd elixir && mix test test/symphony_elixir/claude/cli_runner_test.exs`
Expected: PASS.

```bash
cd elixir && mix format
git add mix.exs lib/symphony_elixir/claude/cli_runner.ex test/symphony_elixir/claude/cli_runner_test.exs
git commit -m "[claude] Build Linear MCP escript and wire --mcp-config"
```

> `.gitignore` the built `symphony_linear_mcp` binary if it is not already ignored (check `elixir/.gitignore`).

---

# Phase 5 — Claude full single-issue e2e (verification)

**Outcome:** A real low-risk Todo issue labeled `agent:claude` is taken end-to-end by Claude: implement → test → PR → Workpad → Human Review. This phase is operational verification, not new unit code. Use the `todo` project (dashboard `127.0.0.1:4011`).

### Task 5.1: Live verification protocol

- [ ] **Step 1: Pre-flight**

Confirm on the `todo` Symphony host: `WORKFLOW.md` has the `claude:` block, `agent.default_runner: codex`, the MCP escript is built and `claude.mcp_server_path` points at it, and `claude` is on PATH for the worker. Run `cd elixir && mix test` once on the host — expect green.

- [ ] **Step 2: Create the issue**

Create a trivially-scoped Todo issue (e.g. "add a `// ` comment header to X") and add the label `agent:claude`. Do not add `agent:codex`.

- [ ] **Step 3: Watch the dashboard**

Confirm the running row shows `runner: claude`, a session id appears, tokens increment, and `last_event` advances. Capture a screenshot for evidence.

- [ ] **Step 4: Verify the contract outputs**

Confirm: a feature branch + Gitea PR exist, CI/Drone ran, the Linear `Codex Workpad` was updated (written via the MCP server), evidence saved to the project's evidence path, and the issue advanced to Human Review. Record any gap as a follow-up issue.

- [ ] **Step 5: Record results**

Append a short run log (issue id, PR url, pass/fail per acceptance bullet) to `docs/superpowers/plans/2026-06-08-symphony-runner-abstraction.md` under a "Phase 5 run log" heading and commit.

---

# Phase 6 — Claude Merging e2e (verification)

**Outcome:** Claude completes the Merging gate with the same rigor as Codex. Operational verification.

### Task 6.1: Merging verification protocol

- [ ] **Step 1: Advance a labeled issue to Merging**

Take a `agent:claude` issue that has a green PR to the `Merging` state.

- [ ] **Step 2: Verify each merge-gate step**

Confirm Claude: reads PR status; confirms CI/Drone green; validates the PR body contains the correct `Closes #issue`; executes the merge; verifies the Linear issue closed post-merge; keeps Workpad/evidence/Human Review consistent. All Linear writes go through the MCP server; all Gitea/Drone actions through workspace tooling.

- [ ] **Step 3: Negative check**

On an issue whose PR CI is red, confirm Claude does NOT merge and instead reports/blocks. Record behaviour.

- [ ] **Step 4: Record results + gate sign-off**

Append a "Phase 6 run log" with per-step pass/fail. **Only after this passes may `agent:claude` be used on real issues at scale** (this is the capability gate from the spec, not a runtime fallback). Commit.

---

# Phase 7 — Failure budget + per-runner stall + dashboard badge

**Outcome:** A runner's runtime failures consume a per-runner budget; exhausting it Blocks the issue (no model switch by default). Capacity retries never count. Stall timeout is per-runner. Dashboard shows the runner.

### Task 7.1: `RunnerFailurePolicy` pure module

**Files:**
- Create: `elixir/lib/symphony_elixir/runner_failure_policy.ex`
- Test: `elixir/test/symphony_elixir/runner_failure_policy_test.exs`

- [ ] **Step 1: Write failing tests for both default and opt-in paths**

```elixir
# elixir/test/symphony_elixir/runner_failure_policy_test.exs
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
             fallback_enabled: true, current: :claude, exhausted: MapSet.new()) ==
             {:switch, :codex}

    assert Policy.on_runtime_failure(3, 3,
             fallback_enabled: true, current: :codex, exhausted: MapSet.new([:claude])) ==
             :block
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd elixir && mix test test/symphony_elixir/runner_failure_policy_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement**

```elixir
# elixir/lib/symphony_elixir/runner_failure_policy.ex
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
```

- [ ] **Step 4: Run to verify pass**

Run: `cd elixir && mix test test/symphony_elixir/runner_failure_policy_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd elixir && mix format
git add lib/symphony_elixir/runner_failure_policy.ex test/symphony_elixir/runner_failure_policy_test.exs
git commit -m "[runner] Add RunnerFailurePolicy budget decision"
```

### Task 7.2: Wire the budget into the orchestrator (persist count, block at budget)

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex` — running-entry map (add `runner_failure_count: 0`), `retry_agent_down/5` (lines 234-246), `schedule_issue_retry/4` metadata (lines 1074-1113) + `pop_retry_attempt_state/3` (1115-1131), and ensure capacity retries in `handle_active_retry/4` (1213-1232) do NOT touch the count.
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`

- [ ] **Step 1: Write a failing test for the block-at-budget decision**

Add an `@doc false` wrapper `next_failure_action_for_test/3` that exposes the orchestrator's mapping from `(runner, failure_count)` to `:retry_same | :block`, and test it:

```elixir
  test "runtime failure blocks once the per-runner budget is exhausted" do
    # budget default 3 from test WORKFLOW.md
    assert SymphonyElixir.Orchestrator.next_failure_action_for_test(:claude, 1) == :retry_same
    assert SymphonyElixir.Orchestrator.next_failure_action_for_test(:claude, 3) == :block
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd elixir && mix test test/symphony_elixir/orchestrator_status_test.exs -k "per-runner budget"`
Expected: FAIL — wrapper undefined.

- [ ] **Step 3: Implement budget wiring**

In `orchestrator.ex`:

- Add `runner_failure_count: 0` to the running-entry map in `spawn_issue_on_worker_host`.
- Add the test wrapper + helper near the other `_for_test` helpers:

```elixir
  @doc false
  @spec next_failure_action_for_test(:codex | :claude, non_neg_integer()) :: :retry_same | :block | {:switch, atom()}
  def next_failure_action_for_test(runner, failure_count), do: next_failure_action(runner, failure_count)

  defp next_failure_action(runner, failure_count) do
    agent = Config.settings!().agent

    SymphonyElixir.RunnerFailurePolicy.on_runtime_failure(failure_count, agent.runner_failure_budget,
      fallback_enabled: agent.runner_fallback_enabled,
      current: runner,
      exhausted: MapSet.new()
    )
  end
```

- Replace `retry_agent_down/5` (line 234) with the budget-aware version:

```elixir
  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    runner = Map.get(running_entry, :runner, :codex)
    failure_count = Map.get(running_entry, :runner_failure_count, 0) + 1

    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} runner=#{runner} failure_count=#{failure_count} reason=#{inspect(reason)}; deciding next action")

    base_metadata = %{
      identifier: running_entry.identifier,
      issue_url: running_entry.issue.url,
      error: "agent exited: #{inspect(reason)}",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      runner: runner,
      runner_failure_count: failure_count
    }

    case next_failure_action(runner, failure_count) do
      :retry_same ->
        schedule_issue_retry(state, issue_id, next_retry_attempt_from_running(running_entry), base_metadata)

      {:switch, other_runner} ->
        schedule_issue_retry(
          state,
          issue_id,
          next_retry_attempt_from_running(running_entry),
          %{base_metadata | runner: other_runner, runner_failure_count: 0}
        )

      :block ->
        Tracker.create_comment(issue_id, "#{runner} exhausted its failure budget after #{failure_count} attempts; moved to Blocked.")
        block_issue_from_entry(state, issue_id, running_entry, "#{runner} exhausted failure budget: #{inspect(reason)}")
    end
  end
```
- In `schedule_issue_retry/4`, add `runner` and `runner_failure_count` to the persisted `retry_attempts` entry (mirror how `worker_host`/`workspace_path` are persisted at lines 1098-1112) and to `pop_retry_attempt_state/3`'s reconstructed `metadata` (lines 1118-1124). When re-dispatching from a retry, pass the persisted `runner` into `do_dispatch_issue` instead of re-deriving from labels (so an opt-in switch sticks). Add a `preferred_runner` param threaded through `dispatch_issue`/`do_dispatch_issue` (default `nil` → derive from labels).
- In `handle_active_retry/4` and the no-slot branch, do NOT increment `runner_failure_count` — only the generic `attempt` increments. Add a code comment: `# capacity retry: not a runner failure`.

- [ ] **Step 4: Run the orchestrator suite**

Run: `cd elixir && mix test test/symphony_elixir/orchestrator_status_test.exs`
Expected: PASS.

- [ ] **Step 5: Full suite**

Run: `cd elixir && mix test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd elixir && mix format
git add lib/symphony_elixir/orchestrator.ex test/symphony_elixir/orchestrator_status_test.exs
git commit -m "[orchestrator] Per-runner failure budget -> Blocked (no default switch)"
```

### Task 7.3: Per-runner stall timeout

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex` — `reconcile_stalled_running_issues/1` (lines 580-597) to choose the timeout by the running entry's `runner`.
- Modify: `elixir/lib/symphony_elixir/config.ex` — add `stall_timeout_ms_for_runner/1`.
- Test: `elixir/test/symphony_elixir/workspace_and_config_test.exs`

- [ ] **Step 1: Write a failing config helper test**

```elixir
  test "stall timeout resolves per runner" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_stall_timeout_ms: 111,
      claude_stall_timeout_ms: 222
    )

    assert SymphonyElixir.Config.stall_timeout_ms_for_runner(:codex) == 111
    assert SymphonyElixir.Config.stall_timeout_ms_for_runner(:claude) == 222
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd elixir && mix test test/symphony_elixir/workspace_and_config_test.exs -k "per runner"`
Expected: FAIL — helper undefined.

- [ ] **Step 3: Implement**

In `config.ex`:

```elixir
  @spec stall_timeout_ms_for_runner(:codex | :claude) :: non_neg_integer()
  def stall_timeout_ms_for_runner(:claude), do: settings!().claude.stall_timeout_ms
  def stall_timeout_ms_for_runner(_runner), do: settings!().codex.stall_timeout_ms
```

In `orchestrator.ex` `reconcile_stalled_running_issues/1`, instead of one top-level `timeout_ms = Config.settings!().codex.stall_timeout_ms`, compute per entry inside the reduce: `timeout_ms = Config.stall_timeout_ms_for_runner(Map.get(running_entry, :runner, :codex))` and keep the existing `timeout_ms <= 0` skip per entry.

- [ ] **Step 4: Run config + orchestrator suites**

Run: `cd elixir && mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/orchestrator_status_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd elixir && mix format
git add lib/symphony_elixir/config.ex lib/symphony_elixir/orchestrator.ex test/symphony_elixir/workspace_and_config_test.exs
git commit -m "[orchestrator] Per-runner stall timeout"
```

### Task 7.4: Dashboard runner badge

**Files:**
- Read first: `elixir/lib/symphony_elixir_web/presenter.ex`, `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`, `elixir/lib/symphony_elixir/status_dashboard.ex`
- Test: `elixir/test/symphony_elixir/status_dashboard_snapshot_test.exs`

- [ ] **Step 1: Locate where a running row is rendered**

Run: `cd elixir && grep -rn "session_id\|worker_host\|identifier" lib/symphony_elixir_web/presenter.ex | head`
Identify the running-row presenter function. The orchestrator snapshot already carries `runner` (Task 2.4).

- [ ] **Step 2: Write a failing snapshot/presenter test**

In `status_dashboard_snapshot_test.exs`, mirror an existing running-row test and assert the presented row includes the runner (e.g. a `:runner` key or a rendered `"claude"` badge string). If the snapshot test builds running entries directly, add `runner: :claude` to the fixture and assert it survives into the presented output.

- [ ] **Step 3: Run to verify failure, then implement**

Add `runner` passthrough in the presenter's running-row map and a small badge in the LiveView template (`<span>{row.runner}</span>` near the existing identifier/worker_host cells). Keep it minimal.

- [ ] **Step 4: Run the dashboard + full suite**

Run: `cd elixir && mix test test/symphony_elixir/status_dashboard_snapshot_test.exs && mix test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd elixir && mix format
git add lib/symphony_elixir_web/presenter.ex lib/symphony_elixir_web/live/dashboard_live.ex test/symphony_elixir/status_dashboard_snapshot_test.exs
git commit -m "[web] Show runner badge on dashboard rows"
```

---

## Final verification

- [ ] Run the whole suite: `cd elixir && mix test` — expect green.
- [ ] Run `cd elixir && mix format --check-formatted` and `mix compile --warnings-as-errors`.
- [ ] Confirm the `WORKFLOW.md` for the `todo` and `ai-note33` projects gains a `claude:` block and `agent.default_runner: codex` before enabling `agent:claude` on real issues (do NOT enable at scale until Phase 6 sign-off).
- [ ] Open a PR from `feat/runner-abstraction`; do not merge the in-flight reserved-slots changes as part of this PR (they are a separate feature in the working tree).

## Spec coverage map

- Deterministic label routing + conflict → Phase 2 (2.3, 2.4)
- `agent:claude` full lifecycle ownership incl. Merging → Phases 3-4 (runner+MCP) + 5-6 (e2e gate)
- Per-runner failure budget → Blocked, no default switch → Phase 7 (7.1, 7.2)
- Capacity retries excluded from budget → Task 7.2 Step 3
- Control-plane comments via `Tracker.create_comment/2` → Tasks 2.4, 7.2
- Event = flat top-level map (`event/timestamp/session_id/usage`) → Task 3.2 (`emit/3`)
- Claude resume via `--resume` → Task 3.3
- MCP adapter (not DynamicTool reuse) → Phase 4
- Config (`claude` block + agent knobs, no `runner_allowed_states`) → Tasks 2.1, 2.2
- Per-runner stall timeout → Task 7.3
- Dashboard runner visibility → Tasks 2.4, 7.4
- Opt-in cross-runner switch, default off → Tasks 2.1 (`runner_fallback_enabled`), 7.1, 7.2
