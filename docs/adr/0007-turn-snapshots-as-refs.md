# 0007: Turn snapshots as commits under `refs/watercoded/`

**Status:** Accepted · 2026-11-08

## Context
"What did the agent change in this turn?" needs the working tree's state at each turn boundary. It's also the
foundation of Tide, the spec's scrubbable timeline. Snapshots must not disturb the user: no commits on their branch,
nothing staged, no stash entries, and it must work in repositories without a configured git identity.

## Decision
Before a turn starts and after it ends, `GitClient.snapshotWorkingTree`:
1. copies the repository's index to a temporary file and points `GIT_INDEX_FILE` at it,
2. runs `git add --all` (honoring `.gitignore`) and `git write-tree`,
3. creates a commit with `git commit-tree` under a fixed "Watercoded" identity,
4. stores it at `refs/watercoded/<current-id>/turn-<n>-{before,after}`.

The refs keep the objects from being garbage-collected. Deleting a Current deletes its refs.

## Consequences
- Per-turn diffs are plain `git diff before after`, and restoring a turn later is `git read-tree`/`checkout`.
- Snapshot commits never appear in `git log` of any branch. List their refs with `git for-each-ref refs/watercoded`; history commands such as `git log --all` can show them too.
- Large untracked files that aren't ignored are captured too. That's the same trade-off `git stash -u` makes.
