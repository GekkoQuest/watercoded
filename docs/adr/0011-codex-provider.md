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
| Models | `model/list` → `data[] {id, displayName, isDefault, defaultReasoningEffort, hidden}` |

## Decision
- `CodexProvider` launches the user's own `codex app-server`; the CLI keeps its own credentials (ADR 0003).
- Permission modes map to Codex's approval policy and sandbox: Ask → `untrusted` + `read-only`;
  Accept Edits → `on-request` + `workspace-write`; Full Access → `never` + `danger-full-access`. Plan mode isn't offered.
- Mid-session model and permission changes are sent with the next `turn/start`.
- Branching uses `thread/fork` through the turn's id (the translator emits it as the turn's checkpoint).
- Server requests Watercoded can't show yet (user-input questions, MCP elicitations, permission profiles) are answered
  with a JSON-RPC error so the turn continues, and a notice says so.
- Background sessions aren't supported yet: the app server lives and dies with the app.

## Consequences
- The app server is experimental and may change. The tested version lives in `CodexProvider`'s `testedVersion`,
  `scripts/doctor.sh` and the README; `WATERCODED_LIVE_CODEX=1 swift test --filter CodexLive` re-verifies it.
- Re-generate the protocol with `codex app-server generate-ts --out <dir>` when upgrading.
