# 0011: Codex through its app server

**Status:** Accepted · 2026-11-09

## Context
Codex is the second real provider. Its CLI offers `codex exec --json` (one-shot) and `codex app-server`
(experimental), a long-lived JSON-RPC 2.0 server over stdio with threads, turns, streaming items, approvals,
resume and fork. Only the app server supports a live, interactive session like Watercoded's.

The protocol was read from the CLI itself (`codex app-server generate-ts`) and confirmed against codex-cli 0.167.0
with live sessions (`CodexLiveTests`, recorded fixtures in `Tests/CodexProviderTests/Fixtures`):

| Feature | Wire format |
|---|---|
| Handshake | `initialize` (clientInfo, capabilities) → response, then the `initialized` notification |
| Session | `thread/start` / `thread/resume {threadId}` / `thread/fork {threadId, lastTurnId}`; result has `thread.id`, `model`, `instructionSources` |
| Turn | `turn/start {threadId, input: [{type: text, text, text_elements}, {type: localImage, path}], effort?, model?, approvalPolicy?, sandboxPolicy?}`; mid-turn messages use `turn/steer {expectedTurnId}` |
| Streaming | `item/agentMessage/delta {itemId, delta}`, then `item/completed` with the full `agentMessage` |
| Tools | `item/started` / `item/completed` for `commandExecution` (status `completed`/`failed`/`declined`, `aggregatedOutput`, `exitCode`), `fileChange` (`changes[].path/diff`), `mcpToolCall`, `webSearch`, `collabAgentToolCall` |
| Approvals | server requests `item/commandExecution/requestApproval` / `item/fileChange/requestApproval`, answered `{decision: accept \| decline}` |
| Usage | `thread/tokenUsage/updated {last, total, modelContextWindow}` after each model response; `account/rateLimits/updated {primary, secondary: {usedPercent, windowDurationMins, resetsAt}, planType}` |
| Turn end | **`thread/status/changed {status: {type: idle}}`.** 0.167.0 never sends `turn/completed` (handled too, in case later versions do). Failures arrive as `error {willRetry: false}` beforehand. |
| Interrupt | `turn/interrupt {threadId, turnId}` |
| Models | `model/list` → `data[] {id, displayName, isDefault, defaultReasoningEffort, supportedReasoningEfforts, hidden}` |
| Plan mode | Experimental API (`initialize` with `experimentalApi: true`): `turn/start {collaborationMode: {mode: plan \| default, settings: {model, reasoning_effort}}}`; the plan arrives as a `plan` item before the turn ends |
| Questions | server request `item/tool/requestUserInput {questions: [{id, header, question, options: [{label, description}]}]}`, answered `{answers: {<id>: {answers: [label]}}}` |
| MCP forms | server request `mcpServer/elicitation/request {serverName, mode: form \| url \| openai/form \| openaiForm \| openai/userVerification, message, requestedSchema \| url}`, answered `{action: accept \| decline \| cancel, content, _meta}` |
| MCP tool approvals | **Also an elicitation**: `_meta.codex_approval_kind: mcp_tool_call` with an empty form; accept runs the tool. With approval policy `never`, Codex refuses MCP tool calls outright. |
| Saved sessions | `~/.codex/sessions/YYYY/MM/DD/rollout-*-<thread id>.jsonl`: a `session_meta` line (`id`, `cwd`, `originator`), then `event_msg` `item_completed` items |

## Decision
- `CodexProvider` launches the user's own `codex app-server`; the CLI keeps its own credentials (ADR 0003).
- Permission modes map to Codex's approval policy and sandbox: Ask → `untrusted` + `read-only`;
  Accept Edits → `on-request` + `workspace-write`; Full Access → `on-request` + `danger-full-access`, with the session
  approving whatever Codex asks for itself (`never` would block every MCP tool);
  Plan → `on-request` + `read-only` with `collaborationMode: plan`.
- Plan mode works like Codex's own "Implement this plan?": the plan is proposed when the planning turn ends; Build
  sends "Implement the plan." in default mode with Ask's permissions, and feedback keeps planning.
- Mid-session model and permission changes are sent with the next `turn/start`.
- Branching uses `thread/fork` through the turn's id (the translator emits it as the turn's checkpoint).
- `request_user_input` questions show as question cards.
- MCP elicitations: tool-call approvals become ordinary approvals; `form` (and OpenAI's variants) and `url` requests show
  as form cards (see `FormRecord`); anything else (e.g. `openai/userVerification`) is declined. Other unknown server
  requests get a JSON-RPC error. Either way the turn continues.
- Background sessions run `codex app-server` under Watercoded's relay (ADR 0009). Reattaching replays the log to rebuild
  the thread, pending approvals, questions and plan; the app server still holds the thread, so no resume is needed.
- Web searches carry `query`, nullable `action` (search query/queries, openPage URL, or findInPage URL/pattern),
  and nullable `results` (opaque JSON array in 0.167.0's generated protocol). A started item can have an empty
  query; completion refreshes the existing card's input and summary. Results are shown when supplied; missing,
  null or empty results get an explicit explanation rather than an empty card. This does not expose page
  contents that Codex does not send.
- Sessions run in Terminal can be imported from the saved session files; ones Watercoded started (`originator:
  watercoded`) aren't offered again.

## Consequences
- The app server is experimental and may change. The tested version lives in `CodexProvider`'s `testedVersion`,
  `scripts/doctor.sh` and the README; `WATERCODED_LIVE_CODEX=1 swift test --filter CodexLive` re-verifies it.
- Re-generate the protocol with `codex app-server generate-ts --experimental --out <dir>` when upgrading. The source
  is at https://github.com/openai/codex (the app server lives in `codex-rs/app-server-protocol`).
- Plan mode depends on the experimental API, the part most likely to change.
