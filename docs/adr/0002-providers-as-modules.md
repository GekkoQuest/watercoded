# 0002: Each AI provider is an isolated module behind `AgentProvider`

**Status:** Accepted · 2026-11-08

## Context
Watercoded will support many agents (Claude Code, Codex, ACP agents such as Gemini CLI and Cursor, local models).
Their wire protocols differ and change often.

## Decision
- `AgentKit` defines the contract: `AgentProvider` (descriptor, availability, start session),
  `AgentSession` (send, respond to approvals, interrupt, terminate) and the normalized `AgentEvent` enum.
- Each provider is its own SwiftPM target that depends only on `AgentKit`, `WatercodedCore` and optionally `ProcessKit`.
- Only the app's composition root (`AppEnvironment`) imports concrete providers and registers them in a `ProviderRegistry`.
- Behavior differences are declared as `ProviderCapabilities`. Orchestration and UI never `switch` on a provider ID.
- Wire translation is a pure value type, tested against recorded transcripts.

## Consequences
- Adding or removing a provider touches one module and one line in the app.
- New provider features need a capability flag (and possibly a new `AgentEvent` case) before the UI can use them.
