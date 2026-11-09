# 0013: GitHub releases and Sparkle updates

**Status:** Accepted · 2026-11-09

## Context

Watercoded should be installed and launched independently of Xcode, and receive new builds from GitHub.
The maintainer is not enrolled in Apple's paid developer program. App Store distribution is not needed.
Writing our own updater would make us responsible for archive validation, replacement and relaunch behavior.

## Decision

- Publish universal, ad-hoc signed Release builds as ZIP assets on public GitHub releases, triggered by version tags.
- Embed Sparkle 2 in the app composition root only. This supersedes the initial zero-runtime-dependencies
  constraint in ADR 0006; WatercodedKit retains its existing dependency structure.
- Embed one stable Ed25519 public key and require signatures on both update archives and feeds, with verification
  before extraction. Keep the private key in Keychain and a GitHub Actions secret. No private key enters the repo.
- Use GitHub's `releases/latest/download/appcast.xml` redirect for a stable feed URL. Each release contains
  a complete signed feed referencing its own versioned archive; a separate feed hosting service is unnecessary.
- Check for updates in Release builds using a quiet sidebar icon with a version tooltip, but require confirmation to install. Leave Debug builds and CLI helper
  modes out of the update lifecycle. Preserve the normal asynchronous application shutdown path.
- Disable hardened runtime library validation for ad-hoc builds, whose missing Team ID otherwise prevents
  loading the embedded Sparkle framework. Retain the rest of hardened runtime.

## Consequences

Downloads may require a per-app Gatekeeper exception at first launch. Apple membership is not required for
this setup. Future Developer ID signing/notarization can improve installation without changing the hosting,
bundle identifier or update key, and should remove the library-validation exception from distribution builds.

The public update key is a lasting compatibility commitment: loss of its private key can require manual
reinstallation. The repository and release assets must remain publicly readable. Build numbers must increase,
and published signed assets must not be edited. Background helper compatibility must be tested when updating
a running installation; building and verifying signatures alone does not establish reconnect behavior.

See [RELEASING.md](../RELEASING.md) for maintenance and verification instructions.
