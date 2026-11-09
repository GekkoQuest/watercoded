# Notes for coding agents

Read [CONTRIBUTING.md](CONTRIBUTING.md) for conventions, and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how
the code is structured. Before pushing, run `make format`, `make lint` and `make test`.

## Bump the version on every push

Every push to `main` ships a new version. In the same push:

1. In `Configs/Base.xcconfig`, bump `MARKETING_VERSION` (semantic versioning, still `0.x`):
   - **Patch** (`0.1.0` → `0.1.1`) for fixes, polish, docs and refactors.
   - **Minor** (`0.1.4` → `0.2.0`) for new features or changed behaviour.
   - **Major** stays `0` until the maintainer decides on 1.0.
2. Increase `CURRENT_PROJECT_VERSION` (the build number) by 1.
3. If the minor version changed, update the README's status line ("early (v0.2)").
4. Tag the pushed commit `v<MARKETING_VERSION>` (e.g. `git tag v0.1.1 && git push origin v0.1.1`).

Several commits pushed together get one bump: include it in the last commit, or add a final
"Bump version to x.y.z" commit.

## Other things to know

- User-facing text uses plain words (session, repository, archive, worktree), never the internal code names
  (`Current`, `Pool`, `settle`, `Channel`). See CONTRIBUTING.
- Watercoded relies on undocumented Claude Code CLI behaviour. Record anything new it depends on in
  `docs/adr/0008-claude-cli-features.md`, and keep the tested CLI version in sync across that ADR,
  `ClaudeCodeProvider`'s `testedVersion`, `scripts/doctor.sh` and the README.
