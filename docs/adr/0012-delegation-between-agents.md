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
Watercoded gives every agent its own MCP server, `watercoded`, with one tool: `delegate(agent, model?, effort?, task)`.

- **Any direction.** The `agent` choices are every non-demo provider registered in the app, so Claude → Codex, Codex →
  Claude, and same-provider/different-model all work, and new providers are delegable automatically. Delegated
  sessions may delegate too, up to `Workspace.maxDelegationDepth` (3) levels.
- **A real session.** The request starts a child Current with the chosen provider, model and effort, in the parent's
  folder (so the parent sees the child's changes) and permission mode. It's shown under the parent in the sidebar;
  its approvals, questions, plans, water and token stats work like any session's.
- **The answer comes back.** When the child's turn ends, its final message is returned as the tool result (failures
  and interruptions come back as tool errors). Deleting or archiving the child answers the waiting parent.
- **Transport.** The MCP server is the app binary in a helper mode (`Watercoded --delegate-mcp <current-id> --agents …
  --mailbox …`, like the relay in ADR 0009). It talks to the app through files in `~/.watercoded/delegation`
  (`requests/` → `claimed/` → `responses/`), so neither side needs a socket and a request is handled once.
- **Trust.** The delegate call itself is pre-approved (Claude: `--allowedTools mcp__watercoded`; Codex:
  `default_tools_approval_mode = "approve"`); everything the child then does asks as usual. Tool timeouts are raised to
  6 hours (`MCP_TOOL_TIMEOUT`, `tool_timeout_sec`) because delegated work takes minutes.
- **Safety.** A child never removes the shared worktree when deleted, can't Land (its parent does), and the Storage
  tab treats a folder as in use while any session using it is open. The MCP server exits if its agent dies.

## Consequences
- Delegation needs Watercoded running: if the app isn't, the request waits in the mailbox until it is (or the tool
  times out).
- Verified end to end by `DelegationLiveTests` (Claude → Codex and Codex → Claude through the real app binary).
