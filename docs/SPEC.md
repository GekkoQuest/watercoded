# Watercoded

> A native macOS home for your coding agents, where the interface behaves like water and the water carries information.

**Status:** Vision and roadmap (spec revision 3, 2026-11-08). The app is at v0.1, and most of this document
describes where it's going, not what ships today. See [What's built today](#whats-built-today).
**Platform:** macOS 26+ (Liquid Glass), with an iOS 26 companion later
**One-liner:** Run every coding agent you already pay for (Claude Code, Codex, Cursor, OpenCode, Gemini, and others) in parallel, each in its own worktree, from one Mac app that feels like it was made by Apple.

## What's built today

| Area | Built (v0.1) | Planned |
|---|---|---|
| Providers | Claude Code (your own CLI), Replay (demo) | Codex, ACP agents (Cursor, Gemini…), OpenCode, Agent SDK for API keys |
| Sessions | Currents in worktrees or your checkout, background sessions that outlive the app, importing CLI sessions | Daemon with event store, remote Reservoirs, containers |
| Conversation | Streaming, approvals, plan mode, questions, task progress, images, `@` files, `/` commands | Quick Composer, queue and steer |
| Review | Changes inspector per session or turn, revert files and hunks, review comments | Terminal, file tree, quick editor, browser preview |
| Shipping | Land: commit, merge or open a pull request | Stacked PRs, Watch PR, other Git hosts |
| Undo | Per-turn git snapshots | Full Tide (side effects), forking |
| Water | Vessels, slosh, shake to settle, droplets, murk, frost, Reduce Motion | Tilt, sound, Pool overview |
| Signature | None yet | Delta, Crosscurrents, the Chart, Springs |
| Platforms | macOS 26, menu bar extra, notifications | iOS companion, App Intents, widgets |

The architecture section (§10) describes the target design. For how the code is structured today, read
[`ARCHITECTURE.md`](ARCHITECTURE.md) and the ADRs in [`adr/`](adr/).

---

## Table of contents

1. [Landscape: what exists today](#1-landscape-what-exists-today)
2. [Gaps nobody has filled](#2-gaps-nobody-has-filled)
3. [Product principles](#3-product-principles)
4. [Core concepts & vocabulary](#4-core-concepts--vocabulary)
5. [The liquid design language](#5-the-liquid-design-language)
6. [Information architecture & screens](#6-information-architecture--screens)
7. [Feature spec](#7-feature-spec)
8. [Signature features (the "why switch" list)](#8-signature-features-the-why-switch-list)
9. [Apple platform integration](#9-apple-platform-integration)
10. [Technical architecture](#10-technical-architecture)
11. [Water engine: technical design](#11-water-engine-technical-design)
12. [Performance budgets](#12-performance-budgets)
13. [Security & trust model](#13-security--trust-model)
14. [Accessibility](#14-accessibility)
15. [Keyboard map](#15-keyboard-map)
16. [Roadmap](#16-roadmap)
17. [Risks & open questions](#17-risks--open-questions)
18. [Sources](#18-sources)

---

## 1. Landscape: what exists today

### 1.1 Closest existing tools

**T3 Code** (pingdotgg, MIT, Electron + web + React Native mobile)
- Architecture: a Node WebSocket **server owns everything**: provider processes, terminals, Git, files. Web, desktop and mobile are thin clients over authenticated, *scoped* RPC.
- **Event-sourced orchestrator**: commands become events. Events, projections and outbox effects commit in a single DB transaction, and an EffectWorker runs side effects. Clients reconnect by replaying the log or resuming from a snapshot.
- **Checkpoints stored as hidden Git refs**, one per turn, so you can diff and restore without polluting the user's branch. A revert is coordinated with the provider conversation and refused if the provider can't roll back.
- Providers: Codex, Claude Code, Cursor, Grok Build, OpenCode, Antigravity, fx (and maybe Kiro). Multiple accounts. Providers can be enabled or disabled per project.
- Worktrees: current checkout / new worktree / reuse previous. Configurable location and branch naming (static prefix, model-chosen `feat/` / `fix/`, or custom instructions). Submodule policy. **Rule-based cleanup**: inactive N days, after settle, after merge, or no new commits, with protection for local changes.
- Git: GitHub, GitLab, Forgejo/Gitea, Bitbucket, Azure DevOps, and more. Generated commit, PR title and PR description (the description includes the checks the thread ran). A full PR page with merging, auto-merge, **stacked PRs**, **linked PRs per thread**, a **`watch_pull_request` agent tool** that wakes the agent on CI failure, comments or conflicts, and **model-written review guides** ("Look closely" stops).
- Inbox model: threads *return to your inbox* when the agent hands back. Settle, snooze, pin, archive. Undo for sidebar actions.
- Remote: T3 Connect tunnel, LAN, Tailscale, SSH-managed hosts. QR pairing with scoped tokens. **Linked environments**, so agents can delegate tasks to other machines.
- Scheduled tasks and **webhook-triggered runs**, with payloads wrapped as untrusted data.
- Remote headless browser shared by agent and human ("Take control").
- Voice dictation, `⌘K` palette, a rich keybinding DSL with `when` clauses.
- Weaknesses: "very very early, expect bugs", about 2k open issues, Electron weight, mostly not accepting contributions. Its own guidelines say to *avoid continuously repainting animations*.

**MonoCode** (hardbeat920, MIT, Tauri + an experimental Rust/GPUI native preview)
- "Tabs are sessions. The composer is the input." Split panes, session folders, archive.
- Wraps CLIs through **structured protocols, not PTY scraping**: Claude stream-json, Codex app-server, **ACP** for Cursor, Grok, Devin, Antigravity and others, HTTP/SSE for OpenCode, RPC for Pi.
- Probes for installed CLIs at startup and disables the missing ones, with an install hint.
- Composer: model, effort, permission mode, attachments, a Plan card with a **Build** button, saved drafts.
- Changes sidebar: stage, discard, commit, push, PR via `gh`. A history graph.
- **`/operator`**: the agent gets a local `app` CLI that controls the app itself (start sessions, choose worktrees, write notes). Idempotent request IDs.
- **Monos**: persistent cross-project agents with memory and scheduled tasks (experimental).
- Remote host daemon installed over SSH (systemd / LaunchAgent / Scheduled Task). Sessions survive the desktop closing.
- Weaknesses: 300+ open issues, a native rewrite in progress, remote mode missing terminals and @-mentions, **remote credentials not stored in the Keychain**, no screen-reader completeness.

**jcode (1jehuang, Rust, ~21k★)**
- Speed is the identity: about 3 MB RAM per extra headless session and about 19 ms to first input (self-reported, against Claude Code at about 169 MB / 3.5 s).
- **Swarm with conflict awareness**: if agent A edits a file agent B has read, B is notified. DM / broadcast between agents. Agents can spawn their own swarm (coordinator and workers).
- Cache-cold warnings, a resume menu with preview, inline images and LaTeX in the TUI, a self-dev mode.

**jcode (cnjack, Go)**
- TUI, web, Tauri desktop and ACP (Zed) share one engine.
- Modes cycled with Shift+Tab: Ask / Plan / Full access.
- **`/goal`**: the agent keeps going until the goal is verified, blocked, or a safety cap is hit.
- **Budget guardrails**: max cost per session plus a warning threshold, fed into the agent's context.
- **SSH mode**: `/ssh user@host`, after which every tool runs remotely with nothing to install. Docker containers as workspaces.
- Color-coded context bar, a live Todo bar, an ask-user multiple-choice tool, browser use with per-site approval, background commands, layered AGENTS.md with `@include`.

### 1.2 The wider field

| Tool | What it nails | Gap |
|---|---|---|
| **Conductor** (Mac, closed) | "Workspace = unit of delegation, PR = unit of integration." **Inline diff comments go straight back to the agent.** A Checks tab gates merge. Create a workspace from a branch, PR, GitHub issue or Linear issue. Archive with restore. | Mac-only, closed source, setup friction for non-Claude agents |
| **Codex app** (OpenAI) | Local / worktree / **cloud** modes. Cloud tasks keep running for 24h with the laptop closed. Automations. | GPT only, no BYO agent |
| **Claude Desktop Code tab** | Parallel sessions, git isolation, side chats, previews, phone dispatch | Claude only |
| **Sculptor** (Imbue) | Each agent runs **in a container**, with "Pairing Mode" syncing to your IDE | Needs Docker Desktop |
| **Intent** (Augment) | A **living spec** shared by Coordinator, Specialists and Verifier. Requirement changes propagate. | Needs an Augment subscription |
| **Nimbalyst** | Kanban of sessions, **file traceability** (which files each agent read and wrote), plans that split into sessions, per-file accept/reject | Electron, no remote |
| **Vibe Kanban** | The kanban board *was* the product | **Shut down** in April 2026, a lesson in vendor risk |
| **Superset / Pane / Emdash / Paseo** | CLI + SDK + MCP for scripting runs, keyboard git, SSH, cross-platform | Mostly utilitarian UIs |
| **Claude Squad** | tmux + worktrees, zero GUI | No diff, no board |
| **Zed / VS Code / JetBrains Air** | Parallel agents inside an editor | Editor-first, agents are secondary |

### 1.3 The table stakes (what Watercoded must ship to be taken seriously)

1. Multiple providers through **structured protocols** (never screen-scraping a PTY)
2. One **worktree per session**, with smart branch naming and cleanup
3. Composer with model, effort, permission mode, attachments, @files, /commands, queue vs steer
4. Plan mode with an approvable plan
5. Diff review with **comments sent back to the agent**
6. Commit / push / PR with generated messages. CI checks visible.
7. Per-turn checkpoints with restore
8. Integrated terminal, file tree, quick editor
9. Background daemon, so sessions survive closing the app
10. Scheduled / recurring agents
11. Remote hosts (SSH) and a mobile companion
12. `⌘K` palette and full keyboard control

---

## 2. Gaps nobody has filled

These came out of the research. Each one is an opportunity:

| # | Gap | Evidence | Watercoded answer |
|---|---|---|---|
| G1 | **No one is truly native Mac.** Everything is Electron, Tauri, web or TUI. | Every tool above | SwiftUI + Liquid Glass + Metal. The first app that feels like Apple made it. |
| G2 | **You can't read agent state at a glance.** Lists of text rows. | T3 inbox, Monocode tabs | The water *is* the status (§5) |
| G3 | **Undo is incomplete.** The Claude SDK file checkpointing doesn't undo Bash changes, subagent edits, or moves and deletes. | Agent SDK docs | **Tide**: full-worktree snapshots per tool call, coordinated with conversation rollback (§8.1) |
| G4 | **Merge conflicts are found too late.** | Conductor says "ask an agent to resolve" | **Crosscurrents**: continuous conflict prediction between parallel sessions (§8.3) |
| G5 | **No shared coordination artifact** between parallel agents (except Intent, which is locked to one vendor). | Augment | **The Chart**: a living spec any agent can read and update (§8.4) |
| G6 | **Comparing attempts is manual.** | Nobody does best-of-N well | **Delta** (§8.2) |
| G7 | **Isolation needs Docker Desktop.** | Sculptor | Apple's native **Containerization** framework on macOS 26 (§9) |
| G8 | **Cheap helper tasks burn paid tokens** (titles, branch names, summaries). | Everyone uses the main model | **On-device Apple Foundation Models**: free, private, instant (§9) |
| G9 | **Remote credentials sit in plaintext files.** | MonoCode docs | Keychain for everything, Secure Enclave-backed device keys |
| G10 | **Accessibility is an afterthought.** | MonoCode native preview | First-class VoiceOver, Reduce Motion, Full Keyboard Access |
| G11 | **Cost is invisible until the bill arrives.** | Only cnjack's jcode has budgets | A cost/usage meter for every session and project, with budgets |

---

## 3. Product principles

1. **Water carries information.** Every liquid behavior means something. If you turn motion off, you lose delight but no information.
2. **Calm by default, alive on demand.** Idle water is still and uses ~0% GPU. Energy shows up only when something is happening.
3. **The agent is the tenant. You are the landlord.** Agents work in isolated worktrees with explicit permissions. You stay in control of merging, pushing and spending.
4. **Bring your own agent.** Never resell tokens. Use the CLIs and logins the user already has.
5. **Native or nothing.** System materials, system text rendering, system shortcuts, Keychain, notifications, Shortcuts. It should feel like Xcode's younger, more playful sibling.
6. **Fast like a utility.** Cold launch in under 400 ms. Typing latency never affected by agent work.
7. **Nothing is lost.** Every turn, file change and side effect can be rewound.
8. **Open protocols.** ACP, MCP and plain git. No lock-in. Vibe Kanban's death is the cautionary tale.

---

## 4. Core concepts & vocabulary

Water names in the chrome, plain names in menus and docs. Every water term has a plain alias the user can switch to (Settings → General → "Use plain names").

| Watercoded | Plain name | Definition |
|---|---|---|
| **Pool** | Project | A git repo (local or remote host) |
| **Current** | Session / thread | One agent conversation, bound to one worktree + branch |
| **Channel** | Worktree | The isolated checkout a Current works in |
| **Tide** | Timeline | The checkpoint history of a Current (§8.1) |
| **Droplet** | Request | Anything waiting on you: an approval, a question, a plan to approve |
| **Delta** | Best-of-N | Several Currents racing the same prompt (§8.2) |
| **Crosscurrent** | Conflict | Two Currents touching overlapping code (§8.3) |
| **Chart** | Spec / plan | Shared living document for a Pool or a group of Currents (§8.4) |
| **Spring** | Automation | A scheduled or webhook-triggered Current (§7.9) |
| **Reservoir** | Host | A machine that runs agents (this Mac, an SSH box, a container) |
| **Shore** | Inbox | Where finished or blocked Currents wash up for you |
| **Settle** | Done | Mark a Current finished. Its water goes still and it leaves the Shore. |

**State machine for a Current:**
```
Draft → Flowing (agent working) ⇄ Waiting (Droplet hanging)
                ↓
            Ashore (handed back for review) → Settled (merged / archived)
                ↓
            Stalled (error, budget hit, crashed)
```

---

## 5. The liquid design language

### 5.1 Material stack

From back to front:

1. **Desktop / wallpaper** (system)
2. **Window glass**: native `.glassEffect` on the sidebar, toolbar and inspector
3. **Water layer**: our own Metal surface that lives *inside* glass vessels (session glyphs, Pool bubbles, the Tide bar, the composer's fill)
4. **Content**: text, code, diffs on solid or near-solid backing for legibility
5. **Floating glass**: composer, Droplets, HUDs, `⌘K`, using `GlassEffectContainer` so they merge and morph

**Rule:** code and long text never sit on moving water. Water lives in vessels, the chrome and transitions, never behind text you're reading.

### 5.2 Water as data (the semantic map)

| Visual | Meaning | Notes |
|---|---|---|
| **Fill level** of a Current's vessel | **Context window used** | The meniscus nears the rim at 80%. Overflow means auto-compact. A "Drain" action triggers compaction and the level drops with a gurgle. |
| **Surface ripples** | Tokens streaming | Amplitude follows tokens per second |
| **Droplet impact** with rings | A tool call happened | Small drop for a read, bigger for a write, splash for a shell command |
| **Clarity** | Health | Clear with caustics = tests and build green. Murky = errors, failing checks, loop detected. |
| **Tint** | Provider | Claude = warm amber, Codex = cool white, Cursor = graphite, etc. Subtle, and the user can override it. |
| **Hanging droplet** at the vessel's top lip | **Needs you** | It wobbles under surface tension and grows over time, so older requests look heavier. Approve = it falls in. Deny = it evaporates. |
| **Bubbles rising** | Subagents / teammates working | One bubble stream per child agent |
| **Temperature shimmer** | Spend rate | Heat haze above the vessel when the cost per minute is high |
| **Ice / frost** | Paused or snoozed | The surface freezes with crystalline edges |
| **Still, mirror-flat** | Idle / settled | Zero simulation |
| **Two droplets merging** | Branch merged | A metaball animation when a PR merges |

### 5.3 Physics: window motion, shake, tilt

**On Mac** (there's no accelerometer, so the *window* is the body of water):
- **Drag the window**: water sloshes toward the trailing edge, then settles with a damped spring. Wave energy scales with velocity.
- **Stop sharply**: a wave runs to the leading edge and *splashes*, with a small haptic tap on the Force Touch trackpad.
- **Shake** (direction reversals): energy builds into chop, then spray, then bubbles, then caustic flashes.
- **Resize**: a gentle swell. (Volume conservation was dropped: the level has to stay a truthful context meter, so physics never changes it.)
- **Move across displays or Spaces**: a gentle swell.
- **Tear a Current out into a new window**: it pulls away as a droplet, stretches, snaps, and becomes a window.
- **Scroll overscroll**: rubber-banding has a slight liquid wobble at the edge, used sparingly.

**On iPhone and iPad** (real sensors):
- **CoreMotion tilt**: the water truly levels against gravity
- **A physical shake** uses the same layered actions as on Mac

### 5.4 Shake actions (layered and safe)

| Intensity | Default action | Opt-in alternatives |
|---|---|---|
| Gentle | Visual only | — |
| Vigorous (≥3 reversals in 600 ms) | A **"Settle?"** HUD with a press-and-hold ring that interrupts the focused Current | "Shake to stir": opens the Pool overview |
| Violent and sustained (≥2 s) | Nothing | "Panic: pause all agents" (requires confirmation) |

Settings → Physics: **intensity** (Still · Calm · Lively · Tsunami), **haptics**, **sound**, and shake bindings.

### 5.5 Liquid Glass usage (native APIs)

- `.glassEffect(.regular.tint(...).interactive(), in: .capsule)` on interactive chips and the composer
- `GlassEffectContainer(spacing:)` around the toolbar cluster, the Droplet stack and the composer accessories, so they **blend when they get close**
- `glassEffectID(_:in:)` with a `@Namespace` for morphs:
  - Composer pill → expanded multi-line composer → Plan card
  - Pool bubble → full Current view
  - Droplet → approval sheet
- `glassEffectUnion` to make grouped chips read as one glass piece
- `backgroundExtensionEffect()` so the sidebar wallpaper bleeds under the inspector
- Never nest `GlassEffectContainer`s (undefined rendering)

### 5.6 Motion & sound vocabulary

- Springs: `.smooth` for UI, and a custom underdamped spring (ζ ≈ 0.35) for liquid
- Default durations: 0.35 s UI, 1.2–2.5 s for water to settle
- Sounds (off by default, subtle): drip (tool call), plink (Droplet appears), pour (merge), gurgle (compact)
- Haptics: `.alignment` for splash, `.levelChange` for approve/deny, `.generic` for crossing a shake threshold

### 5.7 Typography & color

- SF Pro / SF Mono (system). Code uses SF Mono or the user's editor font.
- Semantic colors only, adapting to light, dark and increased contrast
- Water palette: per-appearance base tints, with caustic highlights derived from the accent color

---

## 6. Information architecture & screens

### 6.1 Main window

```
┌──────────────────────────────────────────────────────────────────────────┐
│ ◉◉◉  ⟨Pools⟩  api ▸ fix-auth (Claude · Opus · High)   ◐62%  $1.84  ⌘K   │ glass toolbar
├──────────────┬──────────────────────────────────────────┬────────────────┤
│ SHORE (3)    │                                          │ ⟨Diff⟩ Files   │
│  💧 perf      │   Current stream                        │  Terminal      │
│  ✓ docs      │   ─ messages, tool cards, plan cards     │  Checks  Chart │
│              │   ─ inline diffs, images, HTML renders   │  Browser       │
│ POOLS        │                                          │                │
│ ▾ api        │                                          │                │
│   ◐ fix-auth │                                          │                │
│   ◔ perf  💧  │  ╭──────────────────────────────────╮   │                │
│   ❄ refactor │  │ Composer  @ / 📎  Plan ▾  Steer ⏎ │   │                │
│ ▸ web        │  ╰──────────────────────────────────╯   │                │
├──────────────┴──────────────────────────────────────────┴────────────────┤
│ ≈≈≈●≈≈≈≈●≈≈≈≈≈≈●≈≈≈≈≈≈≈≈●≈≈≈≈≈●≈≈≈≈≈≈≈≈≈▏ Tide                           │
└──────────────────────────────────────────────────────────────────────────┘
```

- **Sidebar**: Shore (inbox) at the top, then Pools with their Currents. Each row shows a small water vessel glyph (level, clarity, Droplet).
- **Toolbar**: breadcrumb with provider · model · effort chips (each opens a picker), the context meter, spend, and the palette.
- **Center**: the Current stream.
- **Inspector**: tabs for Diff · Files · Terminal · Checks · Chart · Browser · Activity.
- **Tide bar**: a horizontal checkpoint river along the bottom.

### 6.2 Pool overview (`⌘0` or "shake to stir")

All live Currents across all Pools appear as **floating glass vessels** on a calm surface.
- Size = recent activity. Level = context. Clarity = health. Hanging droplet = needs you.
- Switch layouts: **Float** (spatial) · **Board** (kanban columns: Flowing / Waiting / Ashore / Settled) · **Grid** (equal tiles with live mini-streams)
- Click a vessel and it morphs (`glassEffectID`) into the full Current view
- Drag a vessel onto another to start a Delta comparison or to link them

### 6.3 Current view (detail)

- **Message stream**: user turns, assistant text, **tool cards** (collapsible, with live output), **plan cards** (approve / edit / build), **question cards** (multiple choice from an ask-user tool), **subagent cards** (each one expandable into its own mini-stream)
- **Inline rendering**: images, Mermaid, LaTeX, HTML previews (sandboxed WKWebView)
- **Sticky bars** above the composer: Todo progress (`Todo 3/7`), active Goal 🎯, budget used
- **Composer**:
  - Model / effort / permission chips
  - `@` files, symbols, URLs, other Currents (as chips)
  - `/` commands and skills
  - Attachments: paste images, drag files, screenshot with ⌘⇧4 straight into the composer
  - **Queue vs Steer** while the agent runs (⏎ queues, ⌘⏎ steers, configurable)
  - Dictation with on-device speech
  - Draft autosave per Current

### 6.4 Review mode (`⌘⇧R`)

- Full-height diff: unified or split, per-commit filter, "since last review" filter
- **Line comments go back to the agent** as a batch ("Send 4 comments")
- **Review guide**: an agent-written reading order with "look closely" stops
- **File traceability**: which files the agent *read* vs *wrote*, and which tool call touched each hunk ("why did this change?" jumps to the tool card)
- Stage or discard per hunk and per file
- Generated commit message, editable, following repo conventions
- Checks panel: CI, tests the agent ran, lint, todos left. Merge is **gated** until they're green, unless you override.

### 6.5 Delta view (§8.2)
### 6.6 Chart view (§8.4)

### 6.7 Menu bar extra

- A tiny water glass showing combined activity. A droplet hangs off it when anything needs you.
- Click for a popover: the Shore list with inline Approve / Deny / Reply, plus a Quick Composer ("new Current in…")

### 6.8 Quick Composer (global hotkey `⌥Space`, configurable)

- A Spotlight-style glass pill from anywhere: type a task, pick a Pool, ⏎. A Current starts in a new worktree.

### 6.9 Settings

General · Appearance & Physics · Providers & Accounts · Models · Permissions · Worktrees · Source Control · Reservoirs (hosts) · Springs · Budgets · Keybindings · Notifications · Privacy · Labs. Settings resolve in layers like T3's: **Current override → Pool → Reservoir → `watercoded.json` in the repo → defaults**, and a layers icon shows where each value comes from.

---

## 7. Feature spec

### 7.1 Providers

| Provider | Transport | Notes |
|---|---|---|
| Claude Code | Claude Agent SDK (TS sidecar) *or* `claude -p --input-format stream-json --output-format stream-json` | Streaming input mode, hooks, `canUseTool`, sessions resume/fork, subagents, MCP, file checkpointing |
| Codex | `codex app-server` (JSON-RPC 2.0 over stdio JSONL) | threads / turns / items, `thread/rollback`, approval requests. Generate types via `generate-ts` / `generate-json-schema`. |
| **ACP family** | Agent Client Protocol | **One adapter covers many agents**: Cursor, Gemini CLI, Grok, Devin, Antigravity, Zed-compatible agents |
| OpenCode | HTTP + SSE | Its server stays on loopback |
| Pi / others | RPC | |
| Any OpenAI-compatible API | Built-in lightweight agent loop (later) | For local models (Ollama / LM Studio / MLX) |

- **Detection**: probe `PATH` (login-shell PATH, not the GUI one) at launch. Missing CLIs show an install hint and an "Install with Homebrew" button.
- **Accounts**: several accounts per provider, switchable per Pool. Usage and quota read where the provider exposes it.
- **Per-Pool enable/disable** of providers
- **Capability matrix** per adapter (rollback? fork? plan mode? images? subagents?). The UI never offers what the adapter can't do.
- **Normalized event model**: adapters translate into `TurnStarted`, `TextDelta`, `ToolCall{kind,input}`, `ToolResult`, `ApprovalRequested`, `QuestionAsked`, `PlanProposed`, `SubagentSpawned`, `Usage{tokens,cost}`, `TurnEnded{reason}`. The UI never branches on provider.

### 7.2 Currents & Channels (sessions & worktrees)

- New Current from: blank prompt, **branch**, **PR**, **GitHub / GitLab / Linear issue**, Spring trigger, Delta, or another Current (fork)
- Channel options: *this checkout* · *new worktree* · *reuse last* · *container* (§9)
- **Branch naming**: on-device model suggests `fix/auth-token-refresh` from the first prompt. A prefix template applies, and you can rename later.
- **Setup scripts** per Pool (`watercoded.json`: `setup`, `run`, `teardown`): install deps, copy `.env` from the main checkout (with consent), warm caches via APFS clonefile (instant, space-free copies of `node_modules`, `target/`, `.build`)
- Per-Channel **port allocation** so parallel dev servers don't collide (`PORT` injected, with discovery of listening ports)
- **Submodule policy** (recursive / top / skip)
- **Cleanup rules** (T3-style): inactive N days / after settle / after merge / no commits. Protects uncommitted, untracked and optionally ignored files. A dry-run "Clean now" shows reasons.
- **Fork a Current**: copies the conversation (SDK `forkSession` / Codex rollback-and-branch) *and* the worktree (new branch from the current Tide point)

### 7.3 Composer & conversation

- Queue vs Steer, interrupt (`⌘.`), retry turn, edit and resend a past user message (creates a fork)
- `/plan`, `/goal <objective>`, `/compact`, `/budget`, `/model`, `/effort`, `/mode`, provider-native slash commands passed through
- **Goal mode**: the agent auto-continues until verified done / blocked / cap reached. A goal bar shows progress and a pause button.
- **Ask-user cards**: render provider questions as tappable options
- **Prompt library**: saved prompts and snippets, shared per Pool via `.watercoded/prompts/`
- **Thread references**: drag a Current into the composer to pass its summary as context

### 7.4 Plan mode

- A Plan card with numbered steps. You can edit step text inline, reorder, delete or add steps.
- Buttons: **Build** (run as-is), **Build in N Channels** (split steps into parallel Currents, Nimbalyst-style), **Refine** (feedback to the agent)
- Plans can be promoted to the **Chart** (§8.4)

### 7.5 Permissions & safety

- Modes per Current: **Ask** · **Accept edits** · **Plan (read-only)** · **Auto** · **Full access** (with a scary red chip)
- Rule editor: allow / ask / deny by tool + path glob + command prefix (maps to SDK allow/deny rules + hooks). "Remember for this Pool" on any approval.
- Safe commands auto-allowed (`ls`, `git status`, `rg`…), with a list you can edit
- **Droplet queue**: all pending approvals across all Currents in one stack. Answer from the window, the menu bar, a notification, Watch or iPhone.
- Network egress policy per Channel when running in a container

### 7.6 Code surfaces

- **Diff viewer** (§6.4): syntax highlighting via tree-sitter, word-level intra-line diff, minimap, `⌘F`
- **File tree** with agent-touch indicators (read = faint ripple, wrote = solid dot)
- **Quick editor**: TextKit 2 (or STTextView), LSP-backed hover / go-to-def later. "Open in Xcode / VS Code / Zed / Cursor" for heavy editing.
- **Terminal** panes: SwiftTerm, one per Channel by default, plus a shared "agent terminal" showing commands the agent runs live
- **Run button**: runs the Pool's `run` script in the Channel. Output is captured and can be sent to the agent ("fix this error").
- **Browser preview** pane: WKWebView pointed at the Channel's dev server port, with element inspector → "send this element to the agent" (screenshot + DOM snippet)

### 7.7 Source control

- Commit / push / **open PR** (`⌘⇧P`) with generated title and body (including tests run and a checks summary)
- Hosts: GitHub first (API + `gh` fallback), then GitLab, Bitbucket, Forgejo/Gitea, Azure DevOps
- **PR page**: status, reviews, comments, checks, merge (merge / squash / rebase), auto-merge
- **Watch PR**: the agent is woken on CI failure, review comments or conflicts (T3's best idea). Visual: the vessel's surface stirs.
- Stacked PRs (later)
- **Strip agent co-author lines on merge**: optional
- History graph per Pool

### 7.8 Context, memory & cost

- **Context meter**: the water level, plus a numeric HUD on hover (tokens used / limit, cache hit %)
- **Cache-cold warning** (jcode): when a Current has been idle past the prompt-cache TTL, the vessel shows a faint frost edge and the next turn is labeled "cold, ~$0.40 to rewarm"
- **Compaction**: auto at a threshold, manual "Drain". The pre-compaction transcript stays in the Tide.
- **Memory layers**: global `~/.watercoded/AGENTS.md` → Pool `AGENTS.md` / `CLAUDE.md` → local untracked notes. Visual editor with `@include`.
- **Notes**: a per-Pool scratchpad that agents can read and write (MCP tool)
- **Budgets**: per Current, Pool, day or month. Warning at 80% (heat shimmer), hard stop at 100% (the Current freezes and a Droplet asks you to extend).
- **Usage dashboard**: spend by provider / Pool / model over time, and subscription quota where available

### 7.9 Springs (automations)

- Triggers: **schedule** (cron and a natural-language picker), **webhook** (GitHub events, generic), **file watch**, **App Intent / Shortcut**, **CI failure on main**
- Destination: new Current each run · one continuing Current · one Current with fresh context
- Payloads are wrapped as **untrusted data**, never as instructions
- Examples shipped as templates: "triage new issues every morning", "bump deps weekly + open PR", "fix main when CI goes red", "summarize yesterday's merged PRs"
- A run log with each run's transcript, cost and outcome

### 7.10 Reservoirs (remote & isolated execution)

- **This Mac** (default)
- **Container** on this Mac via Apple Containerization (§9)
- **SSH host**: Watercoded installs `watercoded-daemon` over SSH (checksum-verified), pairs with a Secure Enclave-backed key, and keeps an SSH tunnel. Sessions survive disconnects.
- **Tailscale** discovery of your own machines
- Reservoir badge on every Pool. Same UI everywhere, no feature gaps remotely (that's MonoCode's weakness).
- Optional cloud reservoirs later (Fly / Hetzner / your own runner image)

### 7.11 Agents controlling Watercoded

- Built-in **MCP server** exposing: `currents.start/list/read/send/stop`, `channels.create/list`, `chart.read/update`, `notes.read/write`, `pr.link/watch`, `droplet.ask`
- Lets a lead agent orchestrate others (MonoCode `/operator`, T3 outside agents). Every app action an agent takes appears in an **Activity** log, and scoped permissions control which ones it can take.
- A `wc` CLI (`wc new "fix flaky test" --pool api`, `wc ls`, `wc attach`) for terminal people

### 7.12 Mobile companion (iOS / iPadOS, later phase)

- Shore list, approvals, reply, start Currents, review diffs, merge PRs
- **Live Activity / Dynamic Island**: a long-running Current shows its water level and status. A droplet appears in the island when approval is needed.
- Watch: approve or deny from the wrist (complication shows the Droplet count)
- Offline read cache
- Real tilt and shake physics (it has an accelerometer!)

---

## 8. Signature features (the "why switch" list)

### 8.1 Tide: undo that includes side effects

The problem: SDK checkpointing doesn't cover Bash, subagent edits, moves or deletes, and conversation rollback is separate from file rollback.

The design:
- Before and after **every tool call** (not every turn), snapshot the whole worktree into a **hidden git ref** (`refs/watercoded/tide/<current>/<seq>`) using `git write-tree` on a temporary index, so the user's index and branch are untouched. That's cheap thanks to git's object dedupe. Very large ignored dirs are excluded, and APFS snapshots are an optional extra.
- Each Tide point stores: conversation position (message UUID / turn ID), tree SHA, tool call, and a small diffstat
- **Scrub** the Tide bar to preview the diff at any point. **Release** to restore:
  - Files → `git read-tree` + checkout of that tree into the Channel
  - Conversation → Claude `fork_session` at that message / Codex `thread/rollback` N turns
  - If the provider can't roll back, offer "restore files only" with a clear warning (T3's rule)
- **Branch from Tide**: start a new Current from any past point (time-travel fork)
- Visual: the bar is a river. Points are pebbles, larger pebbles mean larger changes, and red pebbles mark failed checks. While scrubbing, the main view's water *ebbs*.

### 8.2 Delta: best-of-N

- One prompt goes to N Currents: same model several times, different models, or different providers. Each runs in its own Channel.
- Live side-by-side columns: progress, cost, tests passing, diff size
- Rubric scoring (optional): run the Pool's test command in each Channel, plus an optional reviewer agent that compares the diffs and writes a verdict
- **Pick a winner** → the others are archived. Or **cherry-pick hunks** from several Channels into a merged result.
- Visual: one prompt fans out like a river delta into N channels. When you choose, the losing channels dry up and the winner carries the full flow.
- Naming note: renamed from "Confluence" because Atlassian owns that name for software.

### 8.3 Crosscurrents: predict conflicts before they happen

- The daemon keeps a live map of files and hunks each Current has **read** and **written** (from tool calls)
- Every N seconds, and on each write, run `git merge-tree --write-tree` between Channel branches → **predicted conflicts** with zero checkout cost
- Notify both agents (jcode-style) *and* you. Visual: the two vessels in the overview are joined by a turbulent ribbon. In the file tree the file has a whirlpool icon.
- Actions: "let them coordinate" (sends a mutual message through the MCP mailbox), "pause one", "rebase B on A now"

### 8.4 The Chart: a shared living spec

- A Markdown document per Pool, or per group of Currents (`.watercoded/chart.md`, optionally committed)
- Sections: Goal · Constraints · Decisions · Tasks (with owner Current and status) · Open questions
- Agents read it at turn start and update it through MCP tools. You edit it like a document, and diffs to the Chart show who changed what.
- Tasks in the Chart can be **launched** as Currents with one click. Status flows back automatically.
- Changing a requirement shows a banner on the affected Currents that haven't started or are mid-flight: "Chart changed: re-plan?"

### 8.5 Shore: an inbox you can actually triage

- Only things that need *you*: Droplets, Ashore Currents, failed Springs, PR comments
- Swipe / keyboard actions: approve, reply, review, snooze (it freezes), settle
- Smart grouping by Pool and urgency. Old droplets visibly "grow heavy".

### 8.6 Glanceable state everywhere

The same vessel glyph appears in the sidebar, Dock icon badge (water level + droplet), menu bar, widgets, Live Activity and Watch. You learn one symbol and read the state anywhere.

---

## 9. Apple platform integration

| Capability | Framework | Use |
|---|---|---|
| Liquid Glass | SwiftUI (`glassEffect`, `GlassEffectContainer`, `glassEffectID`) | All chrome |
| Water rendering | Metal compute + SwiftUI `layerEffect` / `distortionEffect` | §11 |
| **On-device LLM** | **Foundation Models** framework | Free, private: Current titles, branch names, commit message *drafts*, Shore summaries, notification text, classifying "is this a question for the user?" |
| **Containers** | **Containerization** framework (macOS 26, lightweight Linux VMs per container) | Isolated Channels without Docker Desktop. Network egress policy. |
| Speech | SpeechAnalyzer (on-device) | Dictation in the composer |
| Shortcuts / Siri / Spotlight | App Intents | "Start a Current in api", "What needs my approval?", Spotlight search over Currents |
| Notifications | UserNotifications, actionable | Approve / Deny / Reply inline |
| Widgets | WidgetKit (desktop + Notification Center) | Pool vessels, Shore count |
| Live Activities | ActivityKit (iOS) | Long runs |
| Focus | Focus Filters | Hide noisy Pools during Focus |
| Keychain + Secure Enclave | Security / CryptoKit | Tokens, device pairing keys |
| Handoff / Continuity | NSUserActivity | Start reviewing on Mac, finish on iPad |
| Haptics | NSHapticFeedbackManager | Splashes, thresholds |
| Display link | `NSView.displayLink` / `CADisplayLink` | 120 Hz sim on ProMotion, synced to the display |
| Services menu / Share | NSServices | "Send selection to Watercoded" from any app |
| Quick Look | QLPreviewing | Preview `.wcchart`, transcripts |
| Sparkle | (3rd-party) | Updates outside the App Store |

---

## 10. Technical architecture

```
┌────────────────────────── Watercoded.app (SwiftUI, macOS 26) ─────────────────────────┐
│  UI (SwiftUI + Liquid Glass)  ·  Water engine (Metal)  ·  Motion input  ·  Editors    │
│  Client runtime (Swift): typed RPC client, local projections cache, optimistic UI     │
└───────────────────────────────▲───────────────────────────────────────────────────────┘
                                │  JSON-RPC over Unix domain socket (local)
                                │  / WebSocket+TLS over SSH tunnel or Tailscale (remote)
┌───────────────────────────────┴────── watercoded-daemon (launchd agent) ─────────────┐
│  Orchestrator (event-sourced): Commands → Events → Projections + Outbox (1 txn)       │
│  Effect workers: provider turns · Tide snapshots · git ops · Springs · PR watchers     │
│  Provider adapters: ClaudeSDK(TS sidecar) · CodexAppServer · ACP · OpenCode · …       │
│  Channel manager (worktrees, containers, ports, setup scripts)                         │
│  Crosscurrents engine (read/write map + merge-tree)                                    │
│  MCP server (agents control the app) · Webhook receiver · Scheduler                    │
│  Store: SQLite (GRDB) — events, projections, transcripts index; blobs on disk          │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### 10.1 Key decisions

| Decision | Choice | Why |
|---|---|---|
| UI | **SwiftUI**, with AppKit where needed (window tracking, text views) | Liquid Glass is native only. AppKit interop for performance-critical text. |
| Daemon language | **Swift** (server-side, structured concurrency) | One language. Runs as a launchd agent. Ships as a Linux binary too, for SSH hosts. |
| Claude integration | **Drive the user's own installed `claude` CLI** (`--input-format/--output-format stream-json`) by default. The **Agent SDK sidecar** is an option for API-key users. | Subscription rules (§17.1): Watercoded must never offer or handle Claude.ai login itself. Spawning the CLI the user installed and logged into keeps auth with Anthropic's own tool. |
| Codex | `codex app-server` directly from Swift | Clean JSON-RPC. Generate Swift types from its JSON Schema. |
| Others | ACP client in Swift | One protocol, many agents |
| State | **Event-sourced**, SQLite via GRDB, command IDs for idempotent retries | Proven by T3: reconnect replay, remote clients, crash safety |
| Git | Shell out to `git` (2.40+, needs `merge-tree --write-tree`) | Maximum compatibility. libgit2 only for hot paths like status. |
| Terminal | SwiftTerm | Mature, native |
| Syntax | tree-sitter (SwiftTreeSitter) | Fast, incremental, many grammars |
| Diff | `git diff` + custom renderer, with word diff via Myers on tokens | Control over visuals |
| Updates | Sparkle (direct) + Mac App Store build later (sandbox limits likely make direct distribution primary) | Agents need broad filesystem and process access |

### 10.2 Repo layout

Implemented. See [ARCHITECTURE.md](ARCHITECTURE.md) for the module map and dependency rules, and [adr/](adr/) for the decisions behind them.

### 10.3 Event schema sketch

```swift
enum WCEvent: Codable {
  case currentCreated(id, pool, channel, provider, model)
  case turnStarted(current, turn, userMessage)
  case textDelta(current, turn, text)
  case toolCalled(current, turn, call: ToolCall)          // kind: read/write/shell/web/mcp/subagent
  case toolFinished(current, call, result, durationMs)
  case tideMarked(current, seq, treeSHA, convoRef, diffstat)
  case dropletRaised(current, droplet: Droplet)           // approval | question | plan
  case dropletResolved(droplet, decision)
  case usage(current, tokensIn, tokensOut, cacheRead, costUSD)
  case contextLevel(current, used, limit)
  case crosscurrent(a, b, files, severity)
  case turnEnded(current, turn, reason)                   // done | interrupted | error | budget | maxTurns
  case currentStateChanged(current, state)                // flowing | waiting | ashore | settled | stalled | frozen
}
```

The UI derives every water parameter from projections of these events. The water engine reads a small `WaterState` struct per vessel (level, clarity, energy, tint, droplets[], frozen).

---

## 11. Water engine: technical design

### 11.1 Simulation

- **2D height field**, damped wave equation, on a low-res grid per vessel (main window ~160×100, glyphs ~24×24, overview vessels ~64×64)
- Metal compute kernel per step: `h_next = (2h - h_prev + c²Δt²∇²h) * damping`, with boundary reflection at the vessel walls
- **Impulses**:
  - Window acceleration → a body-force gradient across the grid (tilt-like slosh)
  - Tool call → a Gaussian drop at a pseudo-random point
  - Token stream → low-amplitude noise injection proportional to tokens/s
  - Droplet fall → large impulse at the top lip
- **Global level** = context %, animated with a spring. Resizing adds a swell but never changes the level.
- **Metaball droplets** (hanging droplet, tear-out, merge) as signed distance fields in a fragment shader

### 11.2 Rendering

- The height map is passed as a texture to a SwiftUI `.layerEffect(ShaderLibrary.water(...))`:
  - Normal from height gradient → **refraction offset** of the layer underneath
  - Fresnel rim + specular from a fixed key light (matches Liquid Glass highlight direction)
  - **Caustics** (when "clear"): a cheap procedural caustic texture modulated by the normals
  - **Turbidity** (when "murky"): noise-based scattering + desaturation
  - **Frost** (frozen): Voronoi crystal edge mask
- Important: **system Liquid Glass can't be customized with shaders.** Our water lives in our own vessels and transition layers. Matching the highlight angle, tint and blur radius to the system glass is a design QA task.

### 11.3 Motion input (Mac)

- Sample `window.frame.origin` every display-link tick (don't rely only on `NSWindow.didMoveNotification`; verify its cadence during live drags on macOS 26)
- Velocity `v` and acceleration `a` via finite differences with a 3-tap smoothing filter
- Slosh force = `-a * k` applied as a gradient
- **Shake detector**: count sign reversals of `a.x` / `a.y` above a threshold within a 600 ms sliding window. Energy accumulator with decay. Thresholds map to the intensity levels in §5.4.
- Also listen to `NSWindow.didChangeScreen`, Space changes, live resize

### 11.4 Energy gating

- Total energy `E = Σ(h² + ḣ²)`. When `E < ε` and no inputs are active, **stop the display link**. Water renders from a cached still frame.
- Pause entirely when the window is occluded (`occlusionState`), the app is hidden, **Low Power Mode** is on, or **thermal state ≥ serious**
- Reduce Motion → no simulation at all. Levels animate with crossfades.

---

## 12. Performance budgets

| Metric | Target |
|---|---|
| Cold launch → interactive | < 400 ms |
| Keystroke → glyph in composer | < 8 ms (never blocked by agent traffic) |
| Stream render | 60 fps with 10 Currents streaming at once |
| Water sim (main window, active) | < 1.5 ms GPU per frame on M1 |
| Water sim (idle) | 0 ms (display link stopped) |
| Memory: app | < 250 MB with 20 Currents loaded |
| Memory: daemon overhead per Current (excluding provider process) | < 10 MB |
| Tide snapshot cost | < 50 ms for a 10k-file repo (index reuse + dedupe) |
| Crosscurrents check | < 200 ms per Channel pair |
| Reconnect after sleep | < 1 s to full state |

Benchmarks run in CI (XCTest performance + Instruments signposts). A public perf page, because jcode shows people care.

---

## 13. Security & trust model

- **Least privilege by default**: new Pools start in Ask mode. Full access requires an explicit per-Pool toggle and shows a persistent red chip.
- **Secrets**: all tokens in the Keychain. Remote device keys in the Secure Enclave. Nothing in plaintext config.
- **Remote pairing**: one-time QR / code, **scoped capabilities** (`currents:read`, `currents:operate`, `terminal:operate`, `fs:write`, `git:push`), revocable per device, expiring
- **Untrusted input**: webhook payloads, PR comments, issue bodies and web pages are wrapped and labeled as data to the agent. Springs triggered by external events default to Plan or Ask mode.
- **Containers** (optional per Pool): filesystem limited to the Channel, network allowlist, no host Keychain
- **Push protection**: pushing to protected branches (main / master / release) always requires a human Droplet
- **Audit log**: every agent action, approval and app-control call, exportable
- **Telemetry**: off by default. Crash reports opt-in. No code or prompts ever leave the machine except to the providers the user chose.

---

## 14. Accessibility

- **Reduce Motion**: no simulation. Levels change with fades. Shake gestures disabled (keyboard alternatives always exist).
- **Reduce Transparency**: glass becomes solid materials. Water vessels become flat gauges.
- **Increase Contrast**: stronger vessel outlines, and clarity/murk shown as an icon too
- **VoiceOver**: every vessel reads its meaning: *"fix-auth, Claude Opus, flowing, context 62 percent, one approval waiting, tests passing."* Rotor items for Droplets and Tide points.
- **Full Keyboard Access**: everything reachable. Tide scrubbable with arrow keys.
- **Color-independent**: provider tint is never the only identifier (name and icon too). Health uses icons as well as clarity.
- **Dynamic Type** on iOS, and respect for the user's text size setting on macOS

---

## 15. Keyboard map

| Action | Shortcut |
|---|---|
| Command palette | `⌘K` |
| Quick Composer (global) | `⌥Space` |
| New Current in this Pool | `⌘N` |
| New Current from branch / PR / issue | `⌘⇧N` |
| Pool overview | `⌘0` |
| Jump to Current 1–9 | `⌘1`…`⌘9` |
| Shore (inbox) | `⌘⇧I` |
| Approve / Deny focused Droplet | `⌘⇧⏎` / `⌘⇧⌫` |
| Next / previous Droplet | `⌥↓` / `⌥↑` |
| Interrupt agent | `⌘.` |
| Steer (send now) / Queue | `⌘⏎` / `⏎` (swappable) |
| Model / Effort / Mode picker | `⌘⇧M` / `⌘⇧E` / `⌘⇧A` |
| Toggle plan mode | `⇧Tab` |
| Review mode | `⌘⇧R` |
| Open PR | `⌘⇧P` |
| Tide: step back / forward | `⌘[` / `⌘]` |
| Toggle terminal / inspector | `` ⌃` `` / `⌘⌥I` |
| Find in Current / diff | `⌘F` |
| Settle Current | `⌘⇧S` |
| Snooze (freeze) | `⌘⌥S` |

Fully rebindable: `~/.watercoded/keybindings.json` with `when` clauses (`composerFocus`, `turnRunning`, `terminalFocus`, `reviewMode`…), in the style of T3.

---

## 16. Roadmap

### Phase 0: Feel prototype (2 weeks)
- A blank SwiftUI window with a Metal water layer in a single vessel
- Window-drag slosh, shake detector + levels, resize swell, haptics
- Simulated "agent" event generator driving level / ripples / droplets / clarity
- **Exit criteria:** it feels great, idle GPU = 0, Reduce Motion fallback works

### Phase 1: MVP, "One great Current" (6–8 weeks)
- Daemon + event store + Unix socket RPC (deferred: the orchestrator runs in-process for now, see ADR 0004)
- Claude adapter (user's own `claude` CLI over stream-json): streaming, approvals, plan mode, interrupts
- Pools, Currents, Channels (worktrees) with setup scripts and branch naming (Foundation Models)
- Stream view, tool cards, composer (queue/steer, @files, images)
- Diff review with comments back to the agent, commit / push / PR (GitHub)
- Vessel glyph everywhere, Shore, Droplets, notifications, menu bar extra
- **Tide v1**: per-tool-call snapshots + restore files + Claude fork
- **Exit criteria:** you'd use it every day instead of the Claude Code CLI

### Phase 2: Parity+ (6 weeks)
- Codex app-server adapter, ACP adapter (Cursor, Gemini…), OpenCode
- Terminal, file tree, quick editor, Run button, browser preview
- Pool overview (Float / Board / Grid)
- Budgets, usage dashboard, cache-cold warnings
- Cleanup rules, Settings layers, keybindings file, `⌘K`
- Watch PR (wake on CI / comments)

### Phase 3: Signature (8 weeks)
- **Delta** best-of-N with test-based scoring and hunk cherry-pick
- **Crosscurrents** conflict prediction + agent mailbox
- **The Chart** with launchable tasks
- MCP server (agents control the app) + `wc` CLI
- Springs (schedule + webhook + CI-red)

### Phase 4: Everywhere (ongoing)
- SSH Reservoirs (Linux daemon build), Tailscale
- Containerization-backed Channels
- iOS / iPadOS companion with Live Activities, Watch approvals
- App Intents / Shortcuts / Spotlight / Widgets / Focus filters
- Stacked PRs, GitLab / Bitbucket / Forgejo

### Success metrics
- Daily active Currents per user, approvals answered within 5 min (Shore works), % of Currents that reach merge, Tide restores used (trust), crash-free sessions > 99.5%, idle energy impact "Low" in Activity Monitor

---

## 17. Risks & open questions

| Risk | Mitigation |
|---|---|
| Water feels gimmicky or distracting | Every effect is semantic. Calm defaults, an intensity slider, Still mode. Test with real users in Phase 0. |
| Battery / thermal impact | Energy gating, occlusion pause, Low Power and thermal awareness, perf CI |
| Provider protocols change under us | Adapters isolated behind a normalized event model. Contract tests against recorded transcripts. A "Replay" provider for development (T3 idea). |
| Claude subscription / auth rules change again | Never handle Claude credentials. The CLI adapter is the default, the SDK adapter is opt-in for API keys. Re-check Anthropic's terms before each release. |
| Mac-only limits the audience | Deliberate positioning. The daemon is portable, so a web client is possible later. |
| Mac App Store sandbox | Ship direct (notarized + Sparkle) first |
| Competing with well-funded tools (Codex app, Claude Desktop, Conductor) | Win on native feel, multi-provider support, Tide / Delta / Crosscurrents, and openness |
| Liquid Glass + custom water mismatch | Design QA pass. Keep water inside our own vessels, never over system glass. |

### 17.1 Decisions (made 2026-11-08)

1. **Open source: yes.** MIT for the app, daemon, adapters and water engine. Optional paid services later (hosted Reservoirs, sync) can fund it without closing the core.
2. **Name:** Watercoded. The water engine's code name is **Meniscus**.
3. **Minimum OS: macOS 26** (and iOS 26 for the companion). No pre-Liquid Glass fallback code.
4. **Claude integration: subscription-aware**:
   - **Watercoded never sees, stores or brokers Claude credentials.** By default it launches the user's own `claude` CLI (installed and authenticated by the user) over stream-json, the way T3 Code and MonoCode work. Whatever plan that CLI is entitled to is between the user and Anthropic.
   - The **Agent SDK sidecar** is a second adapter for users with an **API key** (Console org; some Max/Team plans include monthly API credits). It unlocks SDK-only features (in-process hooks, `canUseTool`, `rewindFiles`).
   - Because Tide (§8.1) does its own git-level snapshots, the CLI adapter loses almost nothing that matters.
5. **Phase 0: done.** The feel prototype validated the water engine, and it now lives on as the `Meniscus` module. Phase 1 is partly built (v0.1); see [What's built today](#whats-built-today).

---

## 18. Sources

- T3 Code: https://github.com/pingdotgg/t3code (README, AGENTS.md, docs/internals/overview.md, docs/user/keybindings.md, project-settings.md, source-control.md, remote-access.md) · https://betterstack.com/community/guides/ai/t3-code/ · https://pyshine.com/T3Code-Minimal-Web-GUI-Coding-Agents/
- MonoCode: https://github.com/hardbeat920/monocode (README, docs/agent-access.md, providers.md, remote-access.md, native/parity.md, install.md) · https://alphasignal.ai/news/monocode-unifies-claude-code-codex-and-cursor-into-one-desktop-app
- jcode: https://github.com/1jehuang/jcode · https://github.com/cnjack/jcode · https://terminaltrove.com/ai-coding-agents/jcode/
- Conductor: https://www.conductor.build/docs (workflow, diff-viewer, checks, agent-modes)
- Comparisons (vendor-authored, treat as opinion): https://nimbalyst.com/blog/best-multi-agent-desktop-apps-claude-code-codex-2026/ · https://nimbalyst.com/blog/best-conductor-alternatives-2026/ · https://www.augmentcode.com/tools/best-ai-coding-agent-desktop-apps · https://pasqualepillitteri.it/en/news/24114/desktop-app-parallel-ai-coding-agents
- Claude Agent SDK: https://code.claude.com/docs/en/agent-sdk/overview (permissions, hooks, sessions, subagents, file-checkpointing, streaming, mcp)
- Codex app-server: https://hexdocs.pm/codex_sdk/0.3.0/09-app-server-transport.html
- Liquid Glass: https://developer.apple.com/documentation/swiftui/glasseffectcontainer · https://developer.apple.com/documentation/swiftui/view/glasseffectid(_:in:)
