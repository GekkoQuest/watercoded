# 0008: Claude CLI features Watercoded enables and how they're verified

**Status:** Accepted · 2026-11-08

## Context
Several features depend on stream-json details that aren't in `claude --help`. These shapes were confirmed
against claude 2.1.319 by reading the CLI and by live sessions (`ClaudeCodeLiveTests`):

| Feature | Wire format |
|---|---|
| Approvals | `control_request` `can_use_tool` → `control_response` `{behavior: allow, updatedInput}` / `{behavior: deny, message}` |
| MCP forms | `control_request` `elicitation {mcp_server_name, message, mode: form \| url, url, requested_schema, property_order}` → `control_response` `{action: accept \| decline \| cancel, content}` (forwarded to stdio clients; verified with an elicitation test server, `Packages/WatercodedKit/Tests/Support/elicitation-mcp-server.py`) |
| Questions | `can_use_tool` for `AskUserQuestion`; answer with `updatedInput.answers[questionText] = label` |
| Plans | `can_use_tool` for `ExitPlanMode` with `input.plan` (Markdown); allow = build, deny with feedback = keep planning |
| Live settings | `control_request` `set_permission_mode {mode}` and `set_model {model}` |
| Compaction | `system` / `compact_boundary` with `compact_metadata.pre_tokens/post_tokens` |
| Manual commands | `/compact`, `/goal`, `/goal <objective>`, `/goal clear` sent as ordinary stream-json user messages |
| Task list | `TaskCreate` / `TaskUpdate` (or `TodoWrite`), only exposed with `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` |
| Billing | `system/init.apiKeySource == "none"` means a subscription; `rate_limit_event.unifiedWindows` gives plan usage |
| Images | user message content blocks `{type: image, source: {type: base64, media_type, data}}` before the text |
| Commands | the `initialize` control response lists `commands` (`name`, `description`, `argumentHint`, `aliases`) |
| Suggested rules | `can_use_tool.permission_suggestions[].rules[] {toolName, ruleContent}` (e.g. `npm test:*`) |
| Saved sessions | `~/.claude/projects/<path with non-alphanumerics → "-">/<session-id>.jsonl`; `isSidechain` marks subagents |

## Decision
- Launch `claude` with `--permission-prompt-tool stdio` and `--allow-dangerously-skip-permissions`. The second flag only
  makes Full Access *selectable* later. The active mode still governs, and the UI confirms before switching to it.
- Set `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` so the task list is available.
- Keep `AskUserQuestion` on its blocking permission-response path. The stdio round-trip regression test in
  `ClaudeQuestionTests` exercises the real `ClaudeCodeSession` against a deterministic protocol peer: a batch of
  single-choice, multi-select and custom answers returns in `updatedInput.answers`, preserving the original
  question input and `multiSelect` flags. This test does not run inference or replace the opt-in live test.
- Ignore unknown message types and fields (`JSONValue` decoding), so new CLI versions degrade gracefully.

## Consequences
- Model menus read the CLI's cached model catalog (`~/.claude/cache/model-catalog/*.json`) for exact versions
  ("Opus 5.5"), alias targets and each model's default effort, plus `model`/`effortLevel` from the user's settings
  (or `ANTHROPIC_MODEL`/`CLAUDE_CODE_EFFORT_LEVEL`). If the cache is missing or changes shape, the built-in list is used.
- Branching from a turn resumes with `--fork-session --resume-session-at <uuid>`, where the uuid is the last
  main-conversation `assistant` line of that turn (verified with 2.1.319: the fork holds only the history up to it,
  and the original session is untouched). The flag only applies in `--print` mode, which Watercoded always uses.
  Live regression tests also confirm that a checkpoint from before `/compact` fails on 2.1.319 with
  `error_during_execution`. Claude therefore does not declare `.branchingAcrossCompaction`: Watercoded disables
  those old branch points with an explanation, keeps their file snapshots, and allows newer turns to branch.
  This includes migration of previously saved checkpoints and protection against compaction racing a snapshot save.
- These are undocumented internals and may change. Unit tests use recorded fixtures. `WATERCODED_LIVE_CLAUDE=1 swift test --package-path Packages/WatercodedKit --filter ClaudeCodeLiveTests` re-verifies them against the installed CLI and should be run when upgrading it.
- The shared composer commands dispatch native `/compact` and `/goal` messages. Claude owns compaction, goal
  evaluation and continuation. Goal availability still follows Claude's workspace trust and hook settings;
  provider refusals must be shown. A command can return text only in its `result` message, so the translator
  exposes successful result text when no assistant text was emitted for the turn, without duplicating normal replies.
  These command forms are documented in [SDK commands](https://code.claude.com/docs/en/agent-sdk/slash-commands)
  and [Goals](https://code.claude.com/docs/en/goal). Unit tests cover dispatch text and result translation;
  manual compaction and goal inspection have also been verified live on 2.1.319. Goal setting and clearing
  remain covered by dispatch tests rather than live inference.
