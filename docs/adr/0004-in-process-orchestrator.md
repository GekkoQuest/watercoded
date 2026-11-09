# 0004: Orchestrate in-process first; extract a daemon later

**Status:** Partly superseded by [0009](0009-background-sessions-via-relays.md) (process lifetime) · 2026-11-08

## Context
The spec calls for a background daemon so agents survive app quits and remote or mobile clients can connect.
Building IPC, auth and a daemon lifecycle before the core loop works would slow everything down.

## Decision
The `Orchestrator` module runs inside the app for v0.1. Its public surface (`Workspace`, `CurrentController`,
`WorkspaceRepository`) is already free of SwiftUI and AppKit, so it can move behind an XPC or socket boundary later without changes to providers.

## Consequences
- Originally, quitting the app ended agent processes. [0009](0009-background-sessions-via-relays.md)
  adds per-session relays so supported agents can outlive the app; orchestration still runs in-process.
  Sessions without a running relay resume via the provider's session ID.
- The daemon becomes its own decision record when it's built.
