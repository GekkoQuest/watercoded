# Architecture

Watercoded is a SwiftUI app (macOS 26+) over a local Swift package, `WatercodedKit`, split into
small modules with one-way dependencies. The app target is only a composition root.

## Module map

| Module | Responsibility | Depends on |
|---|---|---|
| `WatercodedCore` | Domain vocabulary: `Pool`, `Current`, `Channel`, `TranscriptItem`, `UsageSnapshot`, `JSONValue`, `Slug`. Pure value types, all `Sendable`. | — |
| `ProcessKit` | Subprocesses: login-shell `PATH` resolution (`ShellEnvironment`), run-to-completion (`ProcessRunner`), long-lived JSON Lines (`LineStreamingProcess`), and background relays (`RelayHost`, `RelayedProcess`, both behind `LineChannel`). | Core |
| `AgentKit` | The provider contract: `AgentProvider`, `AgentSession`, normalized `AgentEvent`, `ProviderCapabilities`, `ProviderRegistry`. | Core, ProcessKit |
| `GitKit` | `GitClient` (shells out to git; GitHub issues and pull request status via `gh`), `WorktreeManager`, `UnifiedDiff` parser. | Core, ProcessKit |
| `Orchestrator` | `Workspace` (pools + currents), `CurrentController` (one session's state machine), persistence (`WorkspaceRepository`), and per-feature extensions: worktree setup (`WorktreePreparer`), Verify, branching, pull request watching, storage, model options. | Core, ProcessKit, AgentKit, GitKit, Delegation |
| `Meniscus` | Water engine: 1D wave simulation, particles, shake detection, energy-gated display link, Metal `layerEffect` shader. No app knowledge. | — |
| `WatercodedDesign` | Tokens (`Spacing`, `Radius`, `Motion`), glass components, `VesselGlyph` / `ComposerVessel`. | Core, Meniscus |
| `WatercodedUI` | Features: sidebar, Current screen, transcript, composer, approvals, diff inspector, settings, commands, menu bar extra. | Core, AgentKit, GitKit, Orchestrator, Meniscus, WatercodedDesign |
| `ClaudeCodeProvider` | Drives the user's `claude` CLI over stream-json and the stdio control protocol. | Core, AgentKit, ProcessKit |
| `Delegation` | Watercoded's own `delegate` MCP server (run as `Watercoded --delegate-mcp`) and the file mailbox it shares with the app (ADR 0012). | Core |
| `CodexProvider` | Drives the user's `codex app-server` over JSON-RPC: threads, turns, approvals, fork (ADR 0011). | Core, AgentKit, ProcessKit |
| `ReplayProvider` | Scripted offline provider for demos, previews and tests. Records Currents as Codable scripts (`TranscriptRecording`). | Core, AgentKit |
| `OnDeviceIntelligence` | `CurrentSummarizer` backed by Apple's on-device Foundation Models: titles, progress summaries and commit-message drafts. | Orchestrator |

Rules:

1. **Providers are leaves.** They depend only on `AgentKit` and `WatercodedCore` (plus `ProcessKit` if they spawn processes).
   Only the app target imports them (`App/Sources/AppEnvironment.swift`).
2. **Nothing branches on a provider.** Differences are expressed through `ProviderCapabilities`. The UI hides what a provider can't do.
3. **Meniscus knows nothing about agents.** `WatercodedUI/Water/CurrentWater.swift` is the single place that maps a Current's state onto `WaterState`.
4. **UI modules default to `@MainActor`** (SE-0466). Lower layers are `Sendable` values and actors.
5. **Optional services plug in through protocols** owned by the layer that uses them: `CurrentSummarizer`
   (Orchestrator), `TranscriptRecording` (AgentKit). The app target chooses implementations.

## Data flow

```
claude stream-json / codex app-server (optionally through a relay)
                 │ provider session actor + wire translator
                 ▼
          normalized AgentEvent stream
                 │
                 ▼
    CurrentController (@MainActor @Observable)
    transcript · status · usage · approvals · activity
             │                       │
             ▼                       ▼
       SwiftUI views          CurrentWaterSync → Vessel (Meniscus)
             │
    send / approve / interrupt → AgentSession → provider protocol
```

Claude Code uses stream-json plus its stdio control protocol; Codex uses JSON-RPC requests,
responses and notifications. The relay transports protocol lines without interpreting provider events.

## Delegation

`Workspace` polls a `DelegationMailbox` for requests from the app binary's `--delegate-mcp` mode.
Each delegated session gets its own worktree from a snapshot of the parent's files. On its delegated
turn's completion, its changes are applied back only if the patch fits cleanly. Results return through
the mailbox. The GUI must be running to process requests; relays alone do not orchestrate delegation.
See [ADR 0012](adr/0012-delegation-between-agents.md).

## Adding a provider

1. Create `Sources/<Name>Provider/` with a type that conforms to `AgentProvider` and an actor that conforms to `AgentSession`.
2. Translate the provider's wire protocol into `AgentEvent`s. Keep the translator a pure value type and test it against recorded fixtures (see `ClaudeCodeProviderTests/Fixtures`).
3. Declare honest `ProviderCapabilities`.
4. Add the target and product in `Package.swift`, add it to `project.yml`, and register it in `AppEnvironment.live()`.

Claude Code, Codex and Replay are registered today. An ACP adapter is a possible next provider for
Gemini CLI, Cursor and other ACP agents.

## Agent interactions

Beyond text and tool calls, `AgentEvent` covers plans (`planProposed`), multiple-choice questions
(`questionAsked`), task lists (`tasksUpdated`), compaction (`contextCompacted`) and thinking. Sessions can
`answer` questions and switch `setPermissionMode` / `setModel` live. Providers declare these through
`ProviderCapabilities` (`.questions`, `.liveSettings`, `.customModels`) plus `effortLevels`, and protocol
extensions throw `unsupported` for anything a provider doesn't implement.

Async questions use `asyncQuestionAsked`, separate from blocking `questionAsked` requests. Their cards persist in
the transcript and remain actionable after a turn ends; answering sends ordinary conversation input instead of
replying to a suspended provider RPC. Pending async cards also appear in Needs You without marking the agent blocked.

`CurrentController` turns those events into transcript cards and status, raises `AttentionEvent`s
(approvals, plans, questions, finished turns) that become notifications, and records working-tree snapshots
around every turn (see ADR 0007).

## Background sessions

Agents can run under a per-session relay so they outlive the app (ADR 0009). Providers that support it
(`.backgroundSessions`) start through `RelayedProcess` when `SessionConfiguration.relayDirectory` is set, and implement
`reattachSession(_:)`. `CurrentController.prepareForQuit()` saves each session's `RelayHandle` (directory and log offset),
and `Workspace.load()` reattaches every saved relay, including idle sessions ready for review.
Effort changes during a turn are saved for the next idle message; the running turn finishes before its agent is restarted.
A replacement agent waits for the previous process and relay cleanup to finish before reusing its directory.
The app binary doubles as the relay (`Watercoded --relay …`, see `App/Sources/Main.swift`).

## Shipping work

`Workspace.land(_:options:)` commits the channel as the user (hooks run), then merges into the checked-out branch with
safety checks (right branch, clean checkout, automatic abort on conflict), or pushes and opens a pull request with `gh`,
falling back to the host's compare page. The PR description comes from `Workspace.markdown(for:includeTranscript:)`.

## Persistence

`FileWorkspaceRepository` writes versioned JSON envelopes to `~/Library/Application Support/Watercoded/`:
`pools.json`, plus `currents/<id>/current.json` and `transcript.json`. Writes are atomic and coalesced (400 ms).
Worktrees live in `~/.watercoded/worktrees/<pool>/<current>` on branches named `watercoded/<slug>`.
Turn snapshots are commits under `refs/watercoded/<current-id>/turn-<n>-{before,after}` in the repository.
Replay scripts are JSON files in `~/.watercoded/replays/`. Relay logs live in `~/.watercoded/sessions/`
and delegation messages in `~/.watercoded/delegation/`. Preferences use `UserDefaults`.

Debug and Release have different bundle identifiers and preferences but share these file-backed paths.
They should not run concurrently against the same workspace.

When an agent isn't running under the relay (the **Keep agents working after Watercoded quits** setting is off,
the provider lacks `.backgroundSessions`, or the process was stopped), its process ends with the app. Restored
Currents that were mid-flight become *Ready for Review*, and **Resume** or the next message resumes the provider
session (`claude --resume` or `codex resume`).

## The water engine

- `WaterSurface`: a damped wave equation over N columns, solved with 3 substeps per frame (CFL-clamped), with volume conservation. Streaming drives smooth, time-based wave modes rather than per-frame noise; sidebar vessels use slower waves and stronger damping than the composer. It also handles drops, spray and bubbles, and a hanging approval droplet on a spring.
- `MotionTracker`: turns window origin into smoothed velocity and acceleration. Direction reversals within 600 ms count as a shake.
- `WaterEngine`: a single `NSView.displayLink` per window. When every vessel is settled and the window is still, the link pauses. Idle cost is zero.
  It drops to 30 fps in Low Power Mode or under thermal pressure, pauses when the window is occluded, and turns physics off with Reduce Motion.
- `Water.metal`: a SwiftUI `[[stitchable]]` layer effect. It combines the surface and drops as metaballs, refracts the layer beneath, and adds caustics, murk, foam and frost. Highlights and droplet joins adapt to the vessel size; Reduce Transparency disables refraction, caustics and heat shimmer.
  SwiftPM and Xcode compile it into the module's `default.metallib`.

## Testing

`make test` runs Swift Testing suites per module, including:

- recorded `claude` transcripts
- real git worktrees in temporary repositories
- an end-to-end `Workspace` run against `ReplayProvider(pace: 0)`
- physics settling and shake detection

## App distribution

The app target embeds Sparkle for GitHub-hosted updates; package modules have no updater dependency.
`AppUpdater` is created only by the SwiftUI GUI, not by relay/delegation entry points. Release builds
check signed feeds and require confirmation to install; Debug builds leave the updater stopped.
Version tags trigger `.github/workflows/release.yml`. See [RELEASING.md](RELEASING.md) for the
signing-key lifecycle, local installation and distribution without an Apple developer account.
