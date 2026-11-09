# 0009: Background sessions via per-session relays

**Status:** Accepted · 2026-11-08. Partly supersedes [0004](0004-in-process-orchestrator.md)

## Context
Quitting Watercoded killed every running agent, breaking the "nothing is lost" principle. The spec's long-term answer is
a daemon owning all sessions, but moving the orchestrator out of process (XPC, a launchd service, state sync) is a large
change. What users need now is for agents to keep working and for the app to pick them back up.

## Decision
Each agent runs under its own small **relay**: the Watercoded binary started as `Watercoded --relay <dir> <cwd> -- <cli> …`
(the same code also ships as `watercoded-relay` for tests). The relay:

- calls `setsid()` and ignores `SIGHUP`/`SIGPIPE`, so it outlives the app;
- appends everything the agent prints to `output.log`, plus `{"__relay": …}` records for stdin echoes, stderr and the
  exit status;
- reads input from the `input.fifo` named pipe (opened read-write, so clients can come and go);
- exits when the agent does, removing its pipe and pid file.

The app (`RelayedProcess`) tails the log and writes to the pipe. On quit, each Current stores its relay directory and the
log offset it has read. On launch, the provider replays the log up to that offset through a fresh translator to rebuild
state, including approvals that were pending and their inputs, then continues live from the offset. Approvals requested
while the app was closed simply wait in the log.

It's on by default ("Keep agents working after Watercoded quits"). Providers opt in with
`ProviderCapabilities.backgroundSessions`.

## Consequences
- No installation, no launchd plist, and no shared daemon state: one relay per session, gone when the session ends.
- Logs live in `~/.watercoded/sessions/<current-id>/` and are deleted when the session ends.
- The orchestrator still runs in-process. A full daemon (remote clients, scheduled Springs) can later adopt the same
  relays unchanged.
- Verified end to end against claude 2.1.319 by `ClaudeCodeLiveTests` (detach while an approval is pending, reattach,
  approve, finish).
