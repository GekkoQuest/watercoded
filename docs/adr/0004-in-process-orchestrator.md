# 0004: Orchestrate in-process first; extract a daemon later

**Status:** Accepted · 2026-11-08

## Context
The spec calls for a background daemon so agents survive app quits and remote or mobile clients can connect.
Building IPC, auth and a daemon lifecycle before the core loop works would slow everything down.

## Decision
The `Orchestrator` module runs inside the app for v0.1. Its public surface (`Workspace`, `CurrentController`,
`WorkspaceRepository`) is already free of SwiftUI and AppKit, so it can move behind an XPC or socket boundary later without changes to providers.

## Consequences
- Quitting the app ends agent sessions. Restored Currents resume via the provider's session ID.
- The daemon becomes its own decision record when it's built.
