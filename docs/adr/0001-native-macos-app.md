# 0001: Native SwiftUI app for macOS 26+, unsandboxed

**Status:** Accepted · 2026-11-08

## Context
Every comparable tool (T3 Code, MonoCode, Conductor, jcode) is Electron, Tauri, web or a TUI.
Liquid Glass and the water engine need native SwiftUI, Metal and AppKit window access.

## Decision
- SwiftUI app with a minimum of macOS 26, using Liquid Glass APIs (`glassEffect`, `GlassEffectContainer`, `glassEffectID`) directly, with no fallbacks for older versions.
- **Not sandboxed.** Agents run user-installed CLIs (`claude`, `git`, build tools) against arbitrary repositories, and the App Sandbox forbids that.
- Hardened Runtime is on, and distribution is Developer ID + notarization (not the Mac App Store, at least initially).

## Consequences
- Mac-only. A web or iOS client can come later by talking to the orchestrator (see 0004).
- Security comes from permission modes, worktree isolation and the user's own CLI permissions, not from the OS sandbox.
