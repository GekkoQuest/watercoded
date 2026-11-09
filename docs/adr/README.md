# Architecture Decision Records

Short records of decisions that shape the codebase. Add one when a choice is hard to reverse or
surprising. Copy the format of an existing record and number it sequentially.

| # | Decision | Status |
|---|---|---|
| [0001](0001-native-macos-app.md) | Native SwiftUI app for macOS 26+, unsandboxed | Accepted |
| [0002](0002-providers-as-modules.md) | Each AI provider is an isolated module behind `AgentProvider` | Accepted |
| [0003](0003-cli-adapters-own-credentials.md) | Drive users' own CLIs; never handle credentials | Accepted |
| [0004](0004-in-process-orchestrator.md) | Orchestrate in-process first; extract a daemon later | Partly superseded by 0009 |
| [0005](0005-json-file-persistence.md) | Versioned JSON files before a database | Accepted |
| [0006](0006-tooling.md) | XcodeGen + SwiftPM, SwiftFormat owns style, zero runtime dependencies | Partly superseded by 0013 |
| [0007](0007-turn-snapshots-as-refs.md) | Turn snapshots as commits under `refs/watercoded/` | Accepted |
| [0008](0008-claude-cli-features.md) | Claude CLI features Watercoded enables and how they're verified | Accepted |
| [0009](0009-background-sessions-via-relays.md) | Background sessions via per-session relays | Accepted |
| [0010](0010-approval-rules-owned-by-watercoded.md) | Watercoded owns "always allow" rules | Accepted |
| [0013](0013-github-releases-and-sparkle.md) | GitHub releases and Sparkle updates without Developer ID | Accepted |
