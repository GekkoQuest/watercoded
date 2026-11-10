# GitHub releases and app updates

Watercoded ships directly from the public GitHub repository, without the Mac App Store or a paid
Apple developer account. Release builds are ad-hoc signed; they are not Developer ID signed or
notarized. Sparkle 2 verifies both the update feed and downloaded archives using a separate Ed25519 key.

## Install

Download `Watercoded-<version>.zip` from the [latest GitHub release](https://github.com/GekkoQuest/watercoded/releases/latest), extract it and move Watercoded.app
to `/Applications` (or `~/Applications`). Launch the installed copy, rather than an Xcode build.
For an unnotarized download, macOS may require an initial launch attempt followed by
System Settings > Privacy & Security > Open Anyway. Only approve downloads from the trusted repository.
Do not disable Gatekeeper globally.

To install a locally built release instead:

```bash
make install
# Or, for a per-user installation: make install INSTALL_DIR="$HOME/Applications"
```

The install command does not launch or quit the app. It refuses to replace an installation whose
app or helpers are running, and preserves any previous installation in a hidden `.watercoded-backups.noindex` folder for recovery.
Sessions remain in `~/Library/Application Support/Watercoded/`; replacing the app does not remove them.
Xcode and build tools are required to build from source, not to launch the prebuilt app.
User-installed agent CLIs and git are still needed for their respective features. The demo needs git,
but no agent CLI. `git --version` can prompt to install Apple's Command Line Tools if git is missing.

Debug and Release have separate preferences, but share session data, worktrees, replay files and delegation
mailboxes. Run one app at a time; a separate bundle identifier does not isolate those files.

## Updates

Release builds check the feed at
`https://github.com/GekkoQuest/watercoded/releases/latest/download/appcast.xml`.
Each release hosts its own signed feed and ZIP; GitHub's latest-release redirect keeps the feed URL stable.
GitHub Pages is not required. The feed contains the latest full update, so older installed builds can
upgrade directly. Release builds contain both arm64 and x86_64 executables and require macOS 26.

Release builds check quietly at launch and every 10 minutes while the app is running. These are Sparkle
information-only probes: signatures, skipped versions and compatibility are still handled by Sparkle.
Probes respect the automatic-check preference and skip any in-progress update session. A sleeping Mac does
not wake just to check, and an unavailable network waits for a later check. Sparkle's own scheduler remains
intact as a fallback; the additional probes avoid overriding its one-hour scheduled-check minimum.

Watercoded > Check for Updates… checks manually. Scheduled checks reveal an update icon beside Settings in the sidebar footer, without opening a window
or stealing focus, including checks near launch. Hovering shows the available version; clicking the icon
opens Sparkle's review/install window. Manual menu checks still open Sparkle's UI. Dismissing or skipping
an update clears the icon for that update session. Installing and restarting requires confirmation. Automatic downloading/installing is disabled so an
update does not silently interrupt an agent. Normal application termination still runs Workspace.shutdown(),
which saves sessions and detaches supported background agents before quitting. Debug builds are named **Watercoded Development** and use the separate `dev.watercoded.app.debug` bundle
identifier, so Finder and Launch Services do not confuse them with the installed release. They do not start
the updater, and their Check for Updates… menu item is disabled. Relay and delegation processes do not
construct the GUI or start Sparkle.

Test updates with running agents, pending approvals and background sessions before broad distribution.
In particular, helpers use the app executable: existing background processes may keep the older executable
mapped until they finish, while new helper launches use the installed version. Avoid incompatible helper
protocol changes without a migration strategy. A local build/package check cannot establish that a real
Sparkle install and reconnect cycle works; that needs two published versions and an interactive test.

## Signing key (one-time setup)

The Watercoded-specific Sparkle key is stored in the maintainer's login Keychain under account
`dev.watercoded.app`. Its public key is committed as `SUPublicEDKey` in `project.yml` and the generated
`App/Info.plist`. The private key is stored only in Keychain and the `SPARKLE_PRIVATE_KEY` GitHub Actions
repository secret. Never commit it or paste it into logs. Back up the Keychain/key securely: without
Developer ID signing, losing this key can require users to reinstall manually.

To restore the Actions secret from the existing Keychain key (requires `gh auth login`):

```bash
python3 scripts/setup-release-signing.py
```

The script checks that the public key matches the app before uploading. It uses a private temporary file,
deletes it afterward, and never prints the private key. On a replacement Mac, import a secure backup with
Sparkle's `generate_keys --account dev.watercoded.app -f <backup-file>` first. Do not generate a replacement
key for an app already in use and expect existing installations to trust it.

`scripts/sparkle-tools.sh` downloads the matching Sparkle distribution and verifies its pinned SHA-256.
Keep its version/checksum aligned with the exact package version in `project.yml` when upgrading Sparkle.

## Publish

Follow AGENTS.md: bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in Configs/Base.xcconfig,
update the README status for a minor release, then run:

```bash
make format
make lint
make test
# Commit the changes and push main, then tag that commit:
git tag v0.8.5              # example: use the version in Configs/Base.xcconfig
git push origin v0.8.5
```

The Release workflow checks the tag/version and main ancestry, runs lint/tests, builds Release,
packages it with `ditto` (preserving framework symlinks), signs the archive and feed, and publishes both
on a GitHub release. A missing key fails the release instead of shipping an unverifiable update.
The build number must exceed the previous published release's build number. Do not publish older tags
as latest or edit signed release assets after publication. Keep release assets public; private repositories
would require a different authenticated download setup.

The ZIP and signed feed are stored directly as GitHub release assets. The workflow deliberately avoids
a duplicate Actions artifact upload so an outage of the Actions artifact service cannot block publication.

A failed workflow can be retried via workflow_dispatch with its existing tag, provided the release was
not already published. Published versions are immutable: make a new version for corrections.
To check a package locally before publication:

```bash
make build CONFIG=Release
scripts/package-release.sh
```

The script verifies the app's code signature, creates the ZIP, and signs the archive and feed. It refuses
to overwrite an existing output directory; move that directory aside before retrying. These checks do
not exercise Gatekeeper on a downloaded app or a live update/reconnect cycle.

Manual packaging of an already built Release app is available with `scripts/package-release.sh`;
it signs using the local Keychain and writes to `.build/release/v<version>/` without publishing anything.

## Future Developer ID signing

Keep GitHub Releases and Sparkle. Add a Developer ID Application certificate and notarization credentials
to CI, sign the app and nested Sparkle components, notarize and staple before packaging, and remove the
`com.apple.security.cs.disable-library-validation` entitlement from distribution builds. That entitlement
is currently needed because an ad-hoc app has no Team ID for validating the embedded framework.
Preserve the Sparkle public key and bundle identifier so existing installations can update.

References: [Sparkle setup](https://sparkle-project.org/documentation/),
[publishing](https://sparkle-project.org/documentation/publishing/),
[Apple's opening instructions](https://support.apple.com/en-ph/102445).
