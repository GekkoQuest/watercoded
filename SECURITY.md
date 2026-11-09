# Security policy

Watercoded runs AI agents that can read, edit and execute code on your machine. We take that seriously.

## Reporting a vulnerability

Please **don't** describe a vulnerability in a public issue. Use GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository (**Security ▸ Report a vulnerability**). If that option isn't available, open an issue titled
"Security contact request" with no details, and a maintainer will reach out privately. We aim to respond within 72 hours.

## Model

- Watercoded never handles provider credentials. It launches CLIs you've installed and signed in to.
- New sessions default to **Ask** permissions. **Full Access** is opt-in per session and shown in red.
- So that you can switch a running session to Full Access without restarting it, every Claude Code session is
  launched with `--allow-dangerously-skip-permissions`. That flag only *allows* the mode; the session starts in the
  mode you chose, and Watercoded asks for confirmation before switching to Full Access (see ADR 0008).
- Each session runs in its own git worktree by default.
- No telemetry is collected.
