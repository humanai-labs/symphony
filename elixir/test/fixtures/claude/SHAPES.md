# Claude Code `-p --output-format stream-json` shapes (spike, Task 3.0)

Captured from `claude` **2.1.168** with:

```
claude -p --output-format stream-json --verbose --permission-mode acceptEdits "<prompt>" < /dev/null
```

`turn_success.jsonl` is one real successful turn (15 NDJSON lines). Each line is a JSON object with a top-level `type` (and usually `subtype`). The line **sequence** observed:

```
system/hook_started
system/hook_response
system/init            <-- canonical session-start; carries session_id
system/thinking_tokens (×6)
assistant              (×2)   message.content present
user                          (tool_result)
rate_limit_event
assistant
result/success         <-- terminal line; is_error=false, usage{...}, session_id
```

## Fields that matter to the runner

- **`session_id`** appears on EVERY line (including `system/init` and `result`). We capture it from `system/init` and pass `--resume <session_id>` on the next turn.
- **`system/init`** keys include: `session_id`, `model`, `cwd`, `permissionMode`, `mcp_servers`, `tools`, `slash_commands`, `subtype`, `type`, `uuid`. → map to `:session_started`.
- **`result`** keys include: `subtype` ("success" here), **`is_error`** (boolean), `usage`, `result`, `session_id`, `total_cost_usd`, `num_turns`, `stop_reason`, `terminal_reason`, `modelUsage`, `permission_denials`.
  - `usage` has `input_tokens` and `output_tokens` (plus cache fields we ignore).
  - **Pass/fail is driven by `is_error`**, NOT by string-matching the subtype. `is_error == true` → `:turn_failed`; otherwise → `:turn_completed`. (Error turns use subtypes like `error_max_turns` / `error_during_execution` and set `is_error: true`.)

## Parser rules (StreamParser.classify/1)

| line | event |
|---|---|
| `type=system, subtype=init` | `:session_started` (read `session_id`) |
| `type=result, is_error=true` | `:turn_failed` (read `session_id`, `usage`) |
| `type=result` (otherwise) | `:turn_completed` (read `session_id`, `usage`) |
| `type=error` | `:codex_error` |
| everything else (`assistant`, `user`, `rate_limit_event`, other `system/*`) | `:notification` |

## CliRunner note

`claude -p` waits ~3s for stdin before proceeding (it warned "no stdin data received in 3s"). The prompt is passed as an argv, not via stdin, so the spawned command MUST append **`< /dev/null`** to skip that wait.
