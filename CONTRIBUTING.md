# Contributing to Watercoded

Thanks for helping! This guide covers setup, conventions and how changes land.

## Setup

```bash
make bootstrap   # Homebrew tools + Metal Toolchain + generate Watercoded.xcodeproj
make run
make test
```

Use the **Replay (Demo)** provider to work on the UI without spending tokens.

## Project layout

```
App/                      composition root (WatercodedApp, AppEnvironment, AppDelegate) + assets
Configs/                  xcconfig build settings
Packages/WatercodedKit/   all modules and tests (see docs/ARCHITECTURE.md)
docs/                     SPEC.md, ARCHITECTURE.md, adr/
project.yml               XcodeGen spec
```

## Conventions

**Naming**
- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
- One primary type per file, and the file is named after it (`CurrentController.swift`). Small helpers that belong to that type can stay in the file.
- Feature folders in `WatercodedUI` (`Sidebar/`, `Composer/`, …). Views are named `<Thing>View`, `<Thing>Screen` (whole detail areas) or `<Thing>Sheet`.
- Code uses the internal terms `Pool`, `Current`, `Channel`, `shore` and `settle`. User-facing text always uses plain words instead:
  repository, session, worktree, Needs You and archive. Water words belong only to the water visuals.
- Provider modules are named `<Name>Provider`. Their wire types are prefixed with the provider name (`ClaudeWireTranslator`).

**Swift**
- Swift 6 language mode, strict concurrency. UI modules default to `@MainActor`. Lower layers use `Sendable` values and actors.
- Use `any` for existentials (`ExistentialAny` is on).
- Prefer value types. Use `@Observable` classes only for long-lived, UI-observed state.
- Write `///` documentation for public API, and explain *why* in comments rather than *what*.
- Use design tokens (`Spacing`, `Radius`, `Motion`, `Metrics`) instead of magic numbers in views.
- Write user-facing text in sentence case, with no exclamation marks. Errors should say what happened and what to do next.

**Formatting and linting**
- `make format` before committing. CI runs `make lint` (`swiftformat --lint` + `swiftlint --strict`).
- SwiftFormat decides style. If SwiftLint and SwiftFormat disagree, change the SwiftLint config.

**Tests**
- `make test` runs every module's tests in about 20 seconds. Each module prints its own
  "Test run with N tests … passed" line, so the last line only counts the last module, not the total.
  Look for any `✘` or a non-zero exit instead. You'll also see "Executed 0 tests" from XCTest; that's expected.
- Run one module's tests with `swift test --package-path Packages/WatercodedKit --filter GitKitTests`.
- Live tests run the real `claude` CLI and **spend your usage**. They're skipped unless you opt in:
  `WATERCODED_LIVE_CLAUDE=1 make test` (Claude Code) or `WATERCODED_LIVE_CODEX=1 make test` (Codex).
  The MCP live tests start `Tests/Support/elicitation-mcp-server.py` with the system `python3`.
  `WATERCODED_LIVE_DELEGATION=1` runs agents delegating to each other through the built app (`make build` first).
- Swift Testing (`import Testing`, `@Test`, `#expect`), one test target per module.
- Provider translators are tested against recorded fixtures. Re-record them when a CLI changes its format, and redact paths and secrets.
- Prefer real dependencies in temporary directories (git repos) over mocks, and `ReplayProvider(pace: 0)` for orchestration.

**Accessibility**
- Every icon-only control needs a label. Water is never the only signal: pair it with text or an accessibility label.
- Respect Reduce Motion and Reduce Transparency, and support full keyboard access.

## Commits and pull requests

- Use small, focused PRs, and fill in the PR template.
- Write commit subjects in the imperative mood, at most 72 characters (`Add Codex app-server provider`).
- Add an ADR in `docs/adr/` for decisions that are hard to reverse.
- Each TODO must reference an issue: `// TODO(#123): …`.

## Releasing (maintainers)

Version tags trigger the GitHub Release workflow, which checks, builds and packages an ad-hoc signed app,
then publishes a Sparkle-signed update archive and feed. No paid Apple developer account is needed.
Developer ID signing and notarization can be added later. See [docs/RELEASING.md](docs/RELEASING.md)
for installation, signing key setup and release instructions.

The version lives in one place: `MARKETING_VERSION` in `Configs/Base.xcconfig`. Every push to `main` bumps it
(patch for fixes and docs, minor for features), increases `CURRENT_PROJECT_VERSION`, and is tagged
`v<version>`. The README's status line shows the minor version. See [AGENTS.md](AGENTS.md) for the exact steps.
