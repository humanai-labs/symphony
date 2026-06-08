# Symphony Runner 抽象:Linear label = 全生命周期执行权(Codex / Claude)

- 日期:2026-06-08(v2,已按 review 修正核心语义)
- 状态:已对齐,待 writing-plans
- 作者:zfc + Claude
- 范围:第一阶段(单模型单 agent,一步到位跑完整生命周期)

## 0. 核心原则(产品不变量)

**`agent:claude` 不是"先让 Claude 试试",而是"这个 issue 交给 Claude 负责到底"。**

- Linear label 是**执行所有权合同(execution ownership)**,不是 runner 偏好。
- `agent:claude` → Claude 执行该 issue 的**全部 active / merge lifecycle 状态**(Todo → In Progress → Rework → Merging → issue closure),直到完成或 Blocked。
- `agent:codex` 或无 label → Codex。
- runner 自身运行期失败打满**该 runner 的失败预算** → Blocked / Human Review。
- **默认不做跨 runner fallback。** 不会因为状态是 `Merging` 就回落 Codex,也不会失败 N 次后自动切到另一个模型。
- 跨模型接力是**显式 opt-in 的后续能力**(`runner_fallback_enabled: true` 或 `agent:fallback` label),**默认关闭,不进 MVP 默认路径**。

## 1. 背景与目标

Symphony 当前把 Linear issue 派发给固定的 `codex app-server` runner(`AgentRunner` 硬编码 `alias SymphonyElixir.Codex.AppServer`)。目标:让 Linear label 直接决定"这个 issue 由哪个模型负责到底",并新增与 Codex 并列的 Claude runner。

- 在 issue 上用 label `agent:codex` / `agent:claude` 指定执行所有权。
- Symphony 确定性路由到对应 runner,一个 issue 同一时刻只由一个单模型 agent 执行。
- 新增 Claude runner(`claude -p --output-format stream-json --resume`)。
- runner 失败打满预算 → Blocked;默认不换模型。
- 保留并对两个 runner 一致地满足 workspace、Gitea PR、Drone CI、evidence、Workpad、Human Review、**Merging merge gate** 的全部项目合同。

### 第一阶段明确不做(non-goals)

- 多 agent 协作、自动拆任务、自动发布、跨项目迁移、替换 Symphony。
- **默认跨 runner fallback**(保留为 opt-in 后续能力,默认关闭)。
- ~~Claude 不碰 Merging~~ —— **已撤销**:一步到位要求 Claude 同样负责 Merging(见 §5)。

## 2. 关键决策(v2,已按 review 修正)

| 决策 | 选择 | 理由 |
|---|---|---|
| Linear 表达"交给谁" | **label `agent:claude` / `agent:codex`,确定性路由,无 label 默认 Codex** | `Issue.labels` 已解析、`routable?/2` 已基于 label 过滤;label = 执行权 |
| label 语义 | **全生命周期执行所有权(含 Merging),非偏好** | "一步到位,谁的 label 谁负责到底" |
| 双 label 冲突 | **不猜 → skip 派发 + Linear 评论** | 路由必须确定,不臆测 |
| 失败处理 | **同 runner 重试(现有指数退避)至该 runner 失败预算耗尽 → Blocked** | 单模型执行权;有界、不无限烧 token |
| 跨 runner 切换 | **默认关闭**,仅 `runner_fallback_enabled: true` / `agent:fallback` 时启用 | 默认 fallback 会破坏执行所有权 |
| 什么算"runner 失败" | **只算运行期失败**(`turn_failed` / 进程退出 / stall 超时 / 启动失败);`input-required` 走 Blocked;**capacity/no-slot 重试不算** | capacity 重试不是执行失败,不能推进失败预算 |
| Claude 权限姿态 | **对齐 Codex:隔离 workspace 内自动批准 + 工具白名单** | 能真正改代码 / 跑测试 / 出 PR / 执行 merge |
| Claude 多 turn 续跑 | **session 内嵌一个小 Agent 存 resume session_id** | `AgentRunner` 递归循环零改动 |
| Claude 的 Linear 写入 | **新建 stdio MCP server 适配层,复用 `Linear.Client`/`Adapter` 业务逻辑** | `DynamicTool` 是 Codex 工具格式,不能直接当 MCP |
| 控制面自身的 Linear 评论 | **走 `Tracker.create_comment/2`,不走 `linear_graphql`/MCP** | MCP 是给 agent 写 Workpad 的通道,不是控制面依赖 |

## 3. 架构总览

```
Linear ──poll──▶ Orchestrator ─────dispatch─────▶ AgentRunner ───▶ Runner(behaviour)
                 失败预算 / blocked / stall        workspace/hook    ├─ Codex.AppServer  (现有,声明 @behaviour)
                 / 配额 / dashboard / 控制面评论     /prompt          └─ Claude.CliRunner (新增)
                 (Tracker.create_comment)
```

- **完全不动**:`Orchestrator` 的 poll/reconcile/blocked/stall 主体、`Workspace` before/after hook、`PromptBuilder`、WORKFLOW.md 项目合同、dashboard 渲染层。
- **新增**:`SymphonyElixir.Runner` behaviour、`Claude.CliRunner`、纯函数 `RunnerSelection` 与 `RunnerFailurePolicy`、Claude Linear MCP server(适配层)、配置 `claude` 块、running entry 的 `runner` / `runner_failure_count` 字段。
- **小改**:`AgentRunner`(按 runner 选模块)、`Orchestrator`(派发 + 失败预算 + 持久化 runner 上下文 + 控制面评论)、`Config.Schema`(claude 块 + 路由/预算配置)、dashboard snapshot(runner badge)。

## 4. 组件设计(职责 / 接口 / 依赖)

### 4.1 `SymphonyElixir.Runner`(behaviour,新增)

- **职责**:定义 runner 契约,正好是 `AgentRunner` 现在对 `AppServer` 调的三个函数。
- **接口**:
  ```elixir
  @type session :: term()
  @callback start_session(workspace :: Path.t(), opts :: keyword()) :: {:ok, session} | {:error, term()}
  @callback run_turn(session, prompt :: String.t(), issue :: map(), opts :: keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(session) :: :ok
  ```
- **事件契约(强约束,顶层扁平 map)**:两个 runner 都通过 `opts[:on_message]` emit **同一套事件原子**,且 `on_message` 收到的是一个**顶层扁平 map**:
  ```elixir
  %{event: atom(), timestamp: DateTime.t(), session_id: String.t() | nil,
    usage: %{...} | nil, codex_app_server_pid: String.t() | nil, ...}
  ```
  因为现有 `Orchestrator.integrate_codex_update/2` 从**顶层**读 `event` / `timestamp` / `session_id` / `usage`(经 `session_id_for_update` / `maybe_set_usage`),Claude 必须把这些字段放顶层,不能只塞进某个嵌套 metadata。
- **事件原子集**:`:session_started`、`:turn_completed`、`:turn_failed`、`:turn_cancelled`、`:codex_error`、`:tool_call_completed`、`:tool_call_failed`、`:turn_input_required`、`:approval_required`、`:notification`。
- 事件原子名与消息元组 `:codex_worker_update` 第一阶段**保留不改名**(有测试引用,改名纯 churn;语义即"runner 事件")。`codex_app_server_pid` 字段对 Claude 存其 `claude -p` 的 os_pid。
- **依赖**:无(纯契约)。

### 4.2 `Codex.AppServer`(现有,微调)

- `@behaviour SymphonyElixir.Runner`,现有实现已满足三个 callback,无逻辑变化。

### 4.3 `Claude.CliRunner`(新增,核心)

- **职责**:用 Claude Code CLI 执行单 issue 的一个 turn,流式解析 `stream-json`,emit 统一顶层事件。
- **进程模型(与 Codex 唯一结构性差异)**:Codex app-server 长驻、`thread_id` 跨 turn 不变;`claude -p` 一次一 turn 跑完即退,靠 `--resume <session_id>` 续:
  - `start_session/2`:不起 CLI 进程,只构造 session —— 持有 `workspace`、`worker_host` 与一个 `Agent`(轻量持有者)存 `resume_session_id`(初始 `nil`)。
  - `run_turn/4`:`Port.open` spawn 一次 `claude -p`(首 turn 无 `--resume`,后续带上一 turn 的 session_id);逐行解析 stream-json;捕获新 `session_id` 写回持有者;进程退出即 turn 结束。
  - `stop_session/1`:停持有者 Agent,清理残留 Port。
  - **结果**:`AgentRunner.do_run_codex_turns/8` 那套"同一 session 不变地递归往下传"的循环**零改动**。
- **命令(本地)**:
  ```
  claude -p --output-format stream-json --verbose \
    --permission-mode acceptEdits \
    --allowedTools <白名单> \
    --mcp-config <claude-linear-mcp 配置> \
    [--resume <session_id>] \
    "<prompt>"
  ```
  远端走 `SSH.start_port/3`,与 `AppServer.start_port/2` 同构。
- **权限**:`--permission-mode acceptEdits` + `--allowedTools` 白名单(`Bash`、`Edit`、`Write`、`Read`、`Glob`、`Grep` + Claude Linear MCP 写入工具),cwd 锁在 per-issue workspace。沙箱落差见 §8。
- **Merging 无特殊分支**:Merging 状态的 turn 与其它状态走**同一条 `run_turn` 路径**,merge 动作由 prompt + WORKFLOW.md 合同驱动 agent 自己执行(读 PR 状态、校验 CI 绿、校验 PR body、merge、验证 issue closed),不在 runner 里硬编码 merge 逻辑。
- **stream-json 事件映射**(精确字段须在实现首步对照**已安装的 `claude` 版本**核对并固化 fixture):

  | Claude stream-json | Symphony 事件 | 备注 |
  |---|---|---|
  | `{"type":"system","subtype":"init","session_id":...}` | `:session_started` | 捕获 session_id(顶层) |
  | `{"type":"assistant","message":{...}}` | `:notification` | 含 `tool_use` 时另发 `:tool_call_*` |
  | `{"type":"user",...}`(tool_result) | `:tool_call_completed` / `:tool_call_failed` | |
  | `{"type":"result","subtype":"success",...,"usage":{...}}` | `:turn_completed` | usage → 顶层 `:usage` |
  | `{"type":"result","subtype":"error_*"}` | `:turn_failed` | 进失败预算 |
  | `{"type":"error",...}` / 进程非零退出 | `:codex_error` / `{:port_exit, status}` | 进失败预算 |
- **token**:`result.usage` 映射到顶层 `:usage`,自动并入现有 `codex_totals`。
- **超时**:`claude.turn_timeout_ms` / `claude.stall_timeout_ms`;stall 检测读"当前 runner"的超时值。
- **依赖**:`Config`(claude 块)、`SSH`(远端)、Claude Linear MCP 配置生成。

### 4.4 `RunnerSelection`(新增,纯函数,确定性路由)

- **职责**:label → 唯一 runner。**是确定性路由,不是建议。**
- **接口**:
  ```elixir
  @spec from_labels([String.t()], default :: :codex | :claude) ::
          {:ok, :codex | :claude} | {:error, :conflicting_labels}
  ```
  - 含 `agent:claude` 且不含 `agent:codex` → `{:ok, :claude}`
  - 含 `agent:codex` 且不含 `agent:claude` → `{:ok, :codex}`
  - 两者都无 → `{:ok, default}`
  - **两者都有 → `{:error, :conflicting_labels}`**(orchestrator 据此 skip 派发 + 发 Linear 评论,不猜)
  - label 归一化复用 `Issue` 的归一逻辑。
- **依赖**:无。可独立单测。

### 4.5 `RunnerFailurePolicy`(新增,纯函数,失败预算)

- **职责**:把"运行期失败"翻译成"同 runner 再试,还是 Blocked"。默认**不切换模型**。
- **接口**:
  ```elixir
  @spec on_runtime_failure(failure_count :: non_neg_integer(), budget :: pos_integer(), opts :: keyword()) ::
          :retry_same | :block | {:switch, :codex | :claude}
  ```
  - 默认(`fallback_enabled: false`):`failure_count < budget` → `:retry_same`;否则 → `:block`。
  - **具体 trace(budget=3,默认)**:执行1 失败→`:retry_same`、执行2 失败→`:retry_same`、执行3 失败→`:block`。即**同一 runner 共执行 3 次,全失败就直接 Blocked,没有第 4 次,也不换模型**。`agent:codex` 与 `agent:claude` 行为对称。
  - opt-in(`fallback_enabled: true` + 提供另一 runner 与其是否已耗尽):预算耗尽时先 `{:switch, other}`,两个 runner 都耗尽才 `:block`。**默认路径不会产生 `:switch`。**
- **不计入失败预算**:正常完成、`input-required`、capacity/no-slot 重试、issue 离开 active 状态。
- **依赖**:无。可独立单测覆盖默认与 opt-in 两套转移。

### 4.6 `AgentRunner`(小改)

- `run/3` 接受 `opts[:runner]`(`:codex | :claude`),`runner_module/1` 选 `Codex.AppServer` 或 `Claude.CliRunner`,后续全走 behaviour。`build_turn_prompt` / workspace / hook 不变。

### 4.7 `Orchestrator`(小改)

- **派发**:`spawn_issue_on_worker_host` 调 `AgentRunner.run(issue, recipient, attempt:, worker_host:, runner: r)`。初次 `r` 由 `RunnerSelection.from_labels(issue.labels, default_runner)` 决定;`{:error, :conflicting_labels}` → **skip 派发** + `Tracker.create_comment(issue_id, "存在冲突的 agent label,已跳过,请只保留一个")`。
- **持久化 runner 上下文(关键)**:running entry 与 retry metadata 显式新增 `runner`、`runner_failure_count`(以及 opt-in 时的 fallback 状态),随现有 `attempt`/`worker_host`/`workspace_path` 在 `schedule_issue_retry` / `pop_retry_attempt_state` 一并流转。**否则 retry 一次就丢失路由上下文。**
- **运行期失败**:`retry_agent_down` 先 `runner_failure_count + 1`,再调 `RunnerFailurePolicy.on_runtime_failure/3`:
  - `:retry_same` → `schedule_issue_retry`,metadata 带同一 `runner` 与新的 `runner_failure_count`(复用现有指数退避)。
  - `:block` → 进 Blocked(复用 `block_issue_from_entry`)+ `Tracker.create_comment(issue_id, "<runner> 运行期失败已达预算,转人工")`。
  - `{:switch, other}`(仅 opt-in)→ 切 runner、重置 `runner_failure_count` + `Tracker.create_comment`。
- **capacity 重试不算 runner 失败**:`handle_active_retry` 无 slot 时的 `attempt + 1` **不**触碰 `runner_failure_count`。failure budget 与通用 `attempt` 是两个独立计数器。
- **continuation 不计入失败预算**:正常完成但 issue 仍 active 的 continuation 重试,把当前 `runner` 与 `runner_failure_count` **原样带进** continuation metadata,同 runner 续跑、计数不变。
- **控制面评论**:所有 orchestrator 自身发的 Linear 评论(冲突 skip、block、可选 switch)走 `Tracker.create_comment/2`,**不经 `linear_graphql`/MCP**。
- **workspace 不重建**:`Workspace.create_for_issue` 按 identifier 复用;同 runner 重试直接在已有分支/进度上接力。
- **stall**:`reconcile_stalled_running_issues` 用 running entry 的 `runner` 选对应 `*.stall_timeout_ms`。
- **无状态门槛、无回落**:删掉 v1 的 `runner_allowed_states` / "Merging 回落 Codex" 设计。`agent:claude` 在所有 lifecycle 状态都由 Claude 处理。

### 4.8 Claude Linear MCP server(新增,适配层)

- **职责**:把 Symphony 的 Linear 写入能力以 **stdio MCP 协议**暴露给 Claude,使用 Symphony 同一套 Linear auth。
- **不是直接复用 `DynamicTool`**:`DynamicTool` 返回 `%{"success", "output", "contentItems"}` 是 Codex app-server 的 dynamicTools 格式;`tool_specs/0` 也不是 MCP `tools/list` 形状。需实现 MCP `initialize` / `tools/list` / `tools/call`,把请求转成对 `Linear.Client.graphql/3`(或 `Linear.Adapter`)的调用,响应转成 MCP 的 `{content: [...], isError: bool}`。
- **复用**:`Linear.Client` / `Linear.Adapter` 的业务逻辑与 auth;暴露的工具至少覆盖 agent 写 Workpad / issue 状态 / 评论所需(等价于 Codex 侧 `linear_graphql` 的能力面)。
- **结果**:Workpad / 状态 / 评论的写法与 WORKFLOW.md 提示文字对 Codex / Claude 一致。
- **备选(不选,留作降级)**:env 注入 `LINEAR_API_KEY` + 放开 Bash 让 Claude 自己 curl —— 零新代码但绕过统一封装边界、需改提示词。

### 4.9 `Config.Schema`(小改)

WORKFLOW.md front matter:

```yaml
agent:
  default_runner: codex            # 无 agent:* label 时
  runner_failure_budget: 3         # 同一 runner 运行期失败上限,耗尽 → Blocked
  runner_fallback_enabled: false   # 默认关闭;true 才允许跨 runner 切换

claude:
  command: "claude"
  permission_mode: acceptEdits
  allowed_tools: [Bash, Edit, Write, Read, Glob, Grep, mcp__symphony_linear__*]
  turn_timeout_ms: 1800000
  stall_timeout_ms: 600000
```

- `codex` 块不变。新增 `claude` embedded schema + 校验(命令非空、超时 > 0)。
- 新增 `agent.default_runner ∈ {codex, claude}`、`runner_failure_budget > 0`、`runner_fallback_enabled` 布尔。
- **不引入** `runner_allowed_states`(无运行时状态门槛)。

### 4.10 Dashboard(小改)

- snapshot 的 running / retrying / blocked 条目加 `runner` 与 `runner_failure_count`;前端加 runner badge。
- token / session / last_event / status / errors 全走现有通道。

## 5. Merging 纳入 Claude 合同(与 Codex 同一门槛)

第一阶段一步到位 ⇒ `agent:claude` 的 Claude runner 必须满足与 Codex **同一套** Merging 验收门槛(由 agent 按 WORKFLOW.md 用其工具执行,Symphony 不在 runner 内特判):

1. 能读取 PR 状态。
2. 能确认 CI / Drone 绿。
3. 能校验 PR body 含正确 `Closes #issue`。
4. 能执行 merge。
5. merge 后能验证 Linear issue 已关闭。
6. Workpad / evidence / Human Review 合同一致。
7. Gitea / Drone / Linear 写入都走 Symphony 统一工具 / 认证边界(Linear 写入 = §4.8 的 MCP server)。

**capability gate(发布门槛,非运行时回落)**:Claude 必须**先通过 Merging smoke/e2e(MVP 切片 6)**,才可作为 `agent:claude` 上线到真实 issue。这是上线前的能力验收,不是运行时回落 Codex。

## 6. 数据流(默认路径,无切换)

1. poll 命中 `agent:claude` 的 issue(任意 lifecycle 状态)→ `RunnerSelection` 得 `{:ok, :claude}`,`runner_failure_count = 0`。
2. `AgentRunner.run(runner: :claude)` → `Claude.CliRunner` 跑 turn,emit 统一顶层事件 → orchestrator/dashboard 显示。
3. 运行期失败 → `runner_failure_count + 1` → `RunnerFailurePolicy`:`< budget` → 同 runner 重试(指数退避);`== budget` → Blocked + Linear 评论。
4. 正常完成但 issue 仍 active → continuation(同 runner,计数不变)。
5. issue 进入 Merging → 仍是 Claude → 走 §5 门槛 → merge → 验证 issue closed。
6. capacity / no-slot → `attempt + 1`,**不**动 `runner_failure_count`。

## 7. 错误处理

- 运行期失败(`turn_failed` / `:codex_error` / `{:port_exit,_}` / stall / spawn 失败)→ 进 §4.5 失败预算。
- `input-required` / `approval_required` → 维持现状进 Blocked,**不**计入失败预算。
- capacity / no-slot 重试 → 只动通用 `attempt`,不动 `runner_failure_count`。
- Claude resume 失败 → 当运行期失败,落入同 runner 重试 / 预算。
- Claude Linear MCP 调用失败 → 返回 MCP `isError`,agent 可重试;不影响 orchestrator 主循环。
- 控制面发评论失败(`Tracker.create_comment` 返回 error)→ 记 warning,不阻塞状态流转。

## 8. 迁移风险与缓解

- **沙箱落差**:Claude `acceptEdits` 弱于 Codex seatbelt → 锁 cwd + 收紧 `allowedTools`;OS 级沙箱留后续。
- **Merging 是最高危动作(真实 merge)**:门槛后置到切片 6 e2e 通过前不在真实 issue 上启用 `agent:claude`。
- **失败预算是新行为**:现状几乎无限重试,本设计引入"预算耗尽 → Blocked"。预算可配置;务必排除 capacity 重试,避免误判 Blocked。
- **MCP 适配层**:不是包装而是要实现 stdio MCP 协议;先单独 smoke `tools/list`/`tools/call` 再接全链路。
- **resume 可靠性**:长多 turn 续跑失败 → 当运行期失败自动重试。
- **stall 超时**:Claude 节奏不同 → per-runner 超时。
- **在途未提交改动**(`reserved_concurrent_agents_by_state` 配额)→ 在其之上构建,rebase 留意 `orchestrator.ex` 冲突。

## 9. MVP 切片 + 验收

**切片(每步独立可验)**:
1. 抽 `Runner` behaviour,`Codex.AppServer` 声明 —— Codex 纯回归,测试全绿。
2. `RunnerSelection`,label 决定唯一 runner(含双 label 冲突 → skip + 评论);`agent:codex`/无 label 全照旧。
3. `Claude.CliRunner` + stream-json fixture + token/session/event 顶层映射。
4. Claude Linear MCP server,跑通 Workpad / issue comment / state 写入。
5. Claude 完整跑一个真实 issue:实现 → 测试 → PR → Human Review。
6. Claude 完整跑 Merging:CI 绿校验 → PR body `Closes #issue` 校验 → merge → 验证 issue closed。
7. 失败预算:同 runner retry,打满 → Blocked;**不自动换模型**。

**验收标准**:
1. `agent:claude` 的 issue 在所有 lifecycle 状态都路由到 Claude。
2. `agent:codex` / 无 label → Codex(无回归)。
3. 双 label 冲突 → skip + Linear 评论,不臆测。
4. Claude 在真实 issue 上独立完成 实现 / 测试 / PR / Workpad / 进 Human Review。
5. Claude 完整跑 Merging:CI 绿 → PR body `Closes #issue` → merge → issue closed。
6. Claude 运行期失败打满预算 → Blocked,**不自动切 Codex**。
7. (opt-in,默认关闭)仅当 `runner_fallback_enabled: true` 时才发生跨 runner 切换。

## 10. 显式不做

多 agent 协作、自动拆任务、自动发布、跨项目迁移、替换 Symphony;**默认跨 runner fallback**(仅显式 opt-in)。
