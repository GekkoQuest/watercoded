# 0005: Versioned JSON files before a database

**Status:** Accepted · 2026-11-08

## Context
v0.1 stores a handful of pools, currents and their transcripts. Queries are "load everything at launch".

## Decision
`FileWorkspaceRepository` writes one JSON file per entity, wrapped in `{ schemaVersion, value }`, written atomically, with writes coalesced per Current.
`WorkspaceRepository` is a protocol, and `InMemoryWorkspaceRepository` backs tests and previews.

## Consequences
- Zero dependencies and human-readable data.
- Move to SQLite (an event log plus projections, as described in the spec) when scale or daemon requirements justify it. Current search scans loaded transcripts in memory.
  Migrations key off `schemaVersion`.
