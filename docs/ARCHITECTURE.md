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
| `Orchestrator` | `Workspace` (pools + currents), `CurrentController` (one session's state machine), persistence (`WorkspaceRepository`), and per-feature extensions: worktree setup (`WorktreePreparer`), Verify, branching, pull request watching, storage, model options. | Core, AgentKit, GitKit |
| `Meniscus` | Water engine: 1D wave simulation, particles, shake detection, energy-gated display link, Metal `layerEffect` shader. No app knowledge. | — |
| `WatercodedDesign` | Tokens (`Spacing`, `Radius`, `Motion`), glass components, `VesselGlyph` / `ComposerVessel`. | Core, Meniscus |
| `WatercodedUI` | Features: sidebar, Current screen, transcript, composer, approvals, diff inspector, settings, commands, menu bar extra. | everything above |
| `ClaudeCodeProvider` | Drives the user's `claude` CLI over stream-json and the stdio control protocol. | Core, AgentKit, ProcessKit |
| `ReplayProvider` | Scripted offline provider for demos, previews and tests. Records Currents as Codable scripts (`TranscriptRecording`). | Core, AgentKit |
| `OnDeviceIntelligence` | `CurrentSummarizer` backed by Apple's on-device Foundation Models: titles and progress summaries. | Orchestrator |

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
claude (CLI) ──stdout JSONL──► ClaudeCodeSession (actor)
                                 │ ClaudeWireTranslator (pure)
                                 ▼
                            AgentEvent stream
                                 │
                                 ▼
                    CurrentController (@MainActor @Observable)
              transcript · status · usage · pending approvals · activity
                 │                         │
                 ▼                         ▼
          SwiftUI views             CurrentWaterSync → Vessel (Meniscus)
                 │
     user actions (send / approve / interrupt) ──► AgentSession ──stdin JSONL──► claude
```

## Adding a provider

1. Create `Sources/<Name>Provider/` with a type that conforms to `AgentProvider` and an actor that conforms to `AgentSession`.
2. Translate the provider's wire protocol into `AgentEvent`s. Keep the translator a pure value type and test it against recorded fixtures (see `ClaudeCodeProviderTests/Fixtures`).
3. Declare honest `ProviderCapabilities`.
4. Add the target and product in `Package.swift`, add it to `project.yml`, and register it in `AppEnvironment.live()`.

Good next candidates: Codex (`codex app-server`, JSON-RPC over stdio) and an ACP adapter, which covers Gemini CLI, Cursor and other ACP agents with one module.

## Agent interactions

Beyond text and tool calls, `AgentEvent` covers plans (`planProposed`), multiple-choice questions
(`questionAsked`), task lists (`tasksUpdated`), compaction (`contextCompacted`) and thinking. Sessions can
`answer` questions and switch `setPermissionMode` / `setModel` live. Providers declare these through
`ProviderCapabilities` (`.questions`, `.liveSettings`, `.customModels`) plus `effortLevels`, and protocol
extensions throw `unsupported` for anything a provider doesn't implement.

`CurrentController` turns those events into transcript cards and status, raises `AttentionEvent`s
(approvals, plans, questions, finished turns) that become notifications, and records working-tree snapshots
around every turn (see ADR 0007).

## Background sessions

Agents can run under a per-session relay so they outlive the app (ADR 0009). Providers that support it
(`.backgroundSessions`) start through `RelayedProcess` when `SessionConfiguration.relayDirectory` is set, and implement
`reattachSession(_:)`. `CurrentController.prepareForQuit()` saves each session's `RelayHandle` (directory and log offset),
and `Workspace.load()` reattaches. The app binary doubles as the relay (`Watercoded --relay …`, see `App/Sources/Main.swift`).

## Shipping work

`Workspace.land(_:options:)` commits the channel as the user (hooks run), then merges into the checked-out branch with
safety checks (right branch, clean checkout, automatic abort on conflict), or pushes and opens a pull request with `gh`,
falling back to the host's compare page. The PR description comes from `Workspace.markdown(for:includeTranscript:)`.

## Persistence

`FileWorkspaceRepository` writes versioned JSON envelopes to `~/Library/Application Support/Watercoded/`:
`pools.json`, plus `currents/<id>/current.json` and `transcript.json`. Writes are atomic and coalesced (400 ms).
Worktrees live in `~/.watercoded/worktrees/<pool>/<current>` on branches named `watercoded/<slug>`.
Turn snapshots are commits under `refs/watercoded/<current-id>/turn-<n>-{before,after}` in the repository.
Replay scripts are JSON files in `~/.watercoded/replays/`.

When an agent isn't running under the relay (the **Keep agents working after Watercoded quits** setting is off,
the provider lacks `.backgroundSessions`, or the process was stopped), its process ends with the app. Restored
Currents that were mid-flight become *Ready for Review*, and **Resume** or the next message resumes the provider
session (`--resume`).

## The water engine

- `WaterSurface`: a damped wave equation over N columns, solved with 3 substeps per frame (CFL-clamped), with volume conservation. It also handles drops, spray and bubbles, and a hanging approval droplet on a spring.
- `MotionTracker`: turns window origin into smoothed velocity and acceleration. Direction reversals within 600 ms count as a shake.
- `WaterEngine`: a single `NSView.displayLink` per window. When every vessel is settled and the window is still, the link pauses. Idle cost is zero.
  It drops to 30 fps in Low Power Mode or under thermal pressure, pauses when the window is occluded, and turns physics off with Reduce Motion.
- `Water.metal`: a SwiftUI `[[stitchable]]` layer effect. It combines the surface and drops as metaballs, refracts the layer beneath, and adds caustics, murk, foam and frost.
  SwiftPM and Xcode compile it into the module's `default.metallib`.

## Testing

`make test` runs Swift Testing suites per module, including:

- recorded `claude` transcripts
- real git worktrees in temporary repositories
- an end-to-end `Workspace` run against `ReplayProvider(pace: 0)`
- physics settling and shake detection
