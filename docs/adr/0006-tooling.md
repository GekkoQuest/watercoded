# 0006: XcodeGen + SwiftPM, SwiftFormat owns style, zero runtime dependencies

**Status:** Partly superseded by [0013](0013-github-releases-and-sparkle.md) (runtime dependencies) · 2026-11-08

## Decision
- `project.yml` (XcodeGen) generates `Watercoded.xcodeproj`, which isn't committed, so there are no merge conflicts in `pbxproj`.
- All code except the composition root lives in the `WatercodedKit` Swift package, testable with `swift test`.
- SwiftFormat owns formatting (`.swiftformat`). SwiftLint (`.swiftlint.yml`) guards correctness and API hygiene, with style rules that overlap SwiftFormat turned off.
- Swift 6 language mode, `ExistentialAny`, and warnings treated as errors in the app target.
- No third-party runtime dependencies in v0.1. Dev tools come from the `Brewfile`.

## Consequences
A fresh Mac needs only Xcode and Homebrew. `make bootstrap` does the rest.
