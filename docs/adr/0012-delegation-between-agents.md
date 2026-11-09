# 0012: Agents delegating to other agents, across providers

**Status:** Accepted · 2026-11-09

## Context
Users want one agent to hand part of a task to another agent and model, for example Opus delegating to GPT-6.1-Sol,
or Codex asking Claude for a second opinion. Neither CLI does this across providers:

- Claude Code's subagents only run Claude models.
- Codex 0.167.0 has no MCP server mode (it was removed); its "message board" crates coordinate Codex's own agents.
- OpenAI's `codex-plugin-cc` (a Claude Code plugin) delegates Claude → Codex well, but runs Codex inside one Claude
  `Bash` call: Watercoded would see a single command, with Codex's approvals, steps and usage invisible, and only in
  one direction.

## Decision
Watercoded gives every agent its own MCP server, `watercoded`, with three tools:
`delegate(agent, model?, effort?, task, wait?)`, `wait_for_delegations(ids)` and `check_delegations(ids)`.

- **Any direction.** The `agent` choices are every non-demo provider registered in the app, so Claude → Codex, Codex →
  Claude, and same-provider/different-model all work, and new providers are delegable automatically. Delegated
  sessions may delegate too, up to `Workspace.maxDelegationDepth` (3) levels.
- **A real session.** The request starts a child Current with the chosen provider, model and effort, in the parent's
  permission mode. It's shown under the parent in the sidebar; its approvals, questions, plans, water and token stats
  work like any session's.
- **Its own copy of the folder.** Agents can call tools in parallel, and parents may keep working, so a child never
  edits the parent's folder directly. It gets its own worktree, created from a snapshot of the parent's folder
  (uncommitted changes included, ignored files via the repository's worktree setup).
- **Changes come back.** When the child's turn ends, the diff from that snapshot to the child's folder is applied to
  the parent's folder with `git apply`, only if it fits cleanly: if the parent (or another helper) changed the same
  lines meanwhile, nothing is touched and the answer says how to merge (`git diff <base> <result> | git apply --3way`).
- **The answer comes back.** The child's final message, plus what was applied, is the tool result (failures and
  interruptions are tool errors). Deleting or archiving the child answers the waiting parent.
- **Parallel helpers.** `wait: false` answers as soon as the child has started; the parent keeps working and collects
  answers with `wait_for_delegations` (or polls with `check_delegations`). Results are kept in the mailbox's
  `results/` for a day.
- **Transport.** The MCP server is the app binary in a helper mode (`Watercoded --delegate-mcp <current-id> --agents …
  --mailbox …`, like the relay in ADR 0009). It talks to the app through files in `~/.watercoded/delegation`
  (`requests/` → `claimed/` → `responses/`), so neither side needs a socket and a request is handled once.
- **Trust.** The delegate call itself is pre-approved (Claude: `--allowedTools mcp__watercoded`; Codex:
  `default_tools_approval_mode = "approve"`); everything the child then does asks as usual. Tool timeouts are raised to
  6 hours (`MCP_TOOL_TIMEOUT`, `tool_timeout_sec`) because delegated work takes minutes.
- **Safety.** A child can't Land (its changes go to its parent, which lands them); deleting it removes its own copy,
  never its parent's folder. The MCP server exits if its agent dies.

## Consequences
- Delegation needs Watercoded running: if the app isn't, the request waits in the mailbox until it is (or the tool
  times out).
- A child's later turns (if the user keeps talking to it) aren't applied to the parent automatically; only the
  delegated turn is.
- Verified end to end by `DelegationLiveTests`: Claude → Codex and Codex → Claude, and one agent running a Codex and a
  Claude helper in parallel whose separate edits both come back.
