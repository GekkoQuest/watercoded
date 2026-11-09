# 0010: Watercoded owns "always allow" rules

**Status:** Accepted · 2026-11-08

## Context
Approval fatigue pushes people toward Full Access. Claude Code can persist allow-rules itself
(`permission_suggestions` → `.claude/settings.local.json`), but that writes into the working directory (each worktree
separately), only works for Claude, and is invisible in Watercoded.

## Decision
Rules are stored per Pool in Watercoded (`Pool.approvalRules`) and applied by the orchestrator: matching
`can_use_tool` requests are answered "allow" without showing an approval. Claude's own suggestion (e.g. `Bash(npm test:*)`)
is used as the proposed rule when present; otherwise Watercoded proposes one (the program plus subcommand, then ` *`).
After three approvals of the same kind, the approval tray says so next to **Always Allow**.

Prefix rules match the command exactly or followed by a space, so `npm test *` never matches `npm testing` or
`rm -rf / ; npm test`.

## Consequences
- Rules are provider-agnostic, visible and removable in Repository Settings and the Setup inspector, and they never
  touch the user's repository.
- They're as coarse as their pattern. Shell rules are offered per program and subcommand, not per arbitrary command.
