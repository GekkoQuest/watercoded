# Security policy

Watercoded runs AI agents that can read, edit and execute code on your machine. We take that seriously.

## Reporting a vulnerability

Please **don't** describe a vulnerability in a public issue. Use GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository (**Security ▸ Report a vulnerability**). If that option isn't available, open an issue titled
"Security contact request" with no details, and a maintainer will reach out privately. We aim to respond within 72 hours.

## Model

- Watercoded does not manage provider logins or credential storage. It launches CLIs you've installed and
  signed in to; authentication stays with those CLIs.
- New sessions default to **Ask** permissions (configurable in Settings ▸ General). **Full Access** is opt-in per session and shown in red.
- So that you can switch a running session to Full Access without restarting it, every Claude Code session is
  launched with `--allow-dangerously-skip-permissions`. That flag only *allows* the mode; the session starts in the
  mode you chose, and Watercoded asks for confirmation before switching to Full Access (see ADR 0008).
- Each session runs in its own git worktree by default. A worktree isolates file changes, not access to
  the rest of your Mac. Sessions can also run directly in your checkout; imported CLI sessions use it.
- The app is unsandboxed. Agent tools run with the provider's permissions and sandbox; Full Access
  bypasses tool approvals and, for Codex, the filesystem sandbox. Repository setup scripts run directly
  as your user, outside the provider's approval flow.
- Repository approval rules can automatically allow matching tool calls. Delegated sessions inherit
  their parent's permission mode and get their own worktrees; their changes may be applied to the parent.
- Background agents keep running after the app quits by default. Stop sessions before removing their files.
- Transcripts, relay logs and delegation results are local files, not encrypted by Watercoded. They may
  contain sensitive prompts, tool inputs or output. Exports and pull request descriptions can share session
  content; review them before sharing.
- Release builds are ad-hoc signed and not notarized. Sparkle verifies signed update feeds and archives;
  Release builds contact GitHub for update checks. See [release details](docs/RELEASING.md).
- No telemetry is collected.
