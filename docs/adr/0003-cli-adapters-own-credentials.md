# 0003: Drive users' own CLIs; never handle credentials

**Status:** Accepted · 2026-11-08

## Context
As of late 2026, Anthropic doesn't allow third-party products to offer Claude.ai login or use subscription limits on users' behalf.
Subscription OAuth tokens are barred from third-party tools and the Agent SDK. These rules changed several times during 2026.

## Decision
- Watercoded never asks for, stores or forwards provider credentials.
- The Claude Code provider launches the `claude` CLI the user installed and signed in to, using
  `--print --input-format stream-json --output-format stream-json --verbose --include-partial-messages --permission-prompt-tool stdio`.
  Approvals arrive as `control_request` / `can_use_tool` messages and are answered with `control_response`.
- An Agent SDK-based adapter for API-key users can be added later as a separate provider module.

## Consequences
- Plan entitlements are between the user and the provider.
- We depend on CLI wire formats, so fixtures guard them (`ClaudeCodeProviderTests/Fixtures`, recorded from claude 2.1.x).
- Before each release, re-check the provider terms.
