# Contributing

Workflow guide for developing on this repo. For architecture, file classification, constraints, hook reference, runtime layout, and recipes ("how to add X"), see `ARCHITECTURE.md` - that is the single source of truth.

## Prerequisites

| Tool         | Version | Purpose                                   |
| ------------ | ------- | ----------------------------------------- |
| `bash`       | 3.2+    | Scripts (macOS system default is 3.2)     |
| `prek`       | latest  | Pre-commit hook runner (not `pre-commit`) |
| `bats`       | 1.5+    | Bash unit tests                           |
| `pwsh`       | 7.4+    | PowerShell scripts and Pester tests       |
| `jq`         | any     | Scope resolution (`scopes.sh`)            |
| `python3`    | 3.10+   | Pre-commit hook scripts                   |
| `shellcheck` | 0.9+    | Shell linting                             |
| `docker`     | any     | Smoke tests (optional)                    |

## Quick start

```bash
make install     # install pre-commit hooks via prek
make lint        # run hooks on changed files (do this before every commit)
make test-unit   # run bats + Pester unit tests (fast, no Docker)
make test        # run all tests including Docker smoke tests
make help        # list all targets
```

## Development loop

1. Make changes.
2. Run `make lint`. This stages all changes and runs pre-commit hooks.
3. Fix any failures. Re-run `make lint` until clean.
4. Commit.

`make lint` runs `git add --all && prek run`, so it always checks the current working tree. Use `make lint-all` to check every file in the repo, or `make lint-diff` to check only files changed since `main`.

All `lint*` targets accept `HOOK=<id>` to run a single hook (e.g. `make lint-all HOOK=check-zsh-compat`) - seconds instead of minutes when verifying one hook's scope or rule changes across the whole tree. Run `make hooks` to list the available IDs.

## Before you commit

- **CHANGELOG entry.** Every PR that changes runtime files (`nix/`, `.assets/`, `wsl/`) must add an entry under `## [Unreleased]` in `CHANGELOG.md`. Enforced by `check-changelog`. Doc-only / test-only PRs can use the `skip-changelog` PR label.
- **Lint clean.** `make lint` must pass. Don't `--no-verify` - fix the underlying issue.
- **Tests pass.** `make test-unit` must pass. The smart test runners (`bats-tests`, `pester-tests`) auto-run relevant tests on changed files.
- **Constraints respected.** Bash 3.2 / zsh-compat / file-shebang rules are enforced by hooks; if one fires, see `ARCHITECTURE.md` §7 for the rule and the rationale.

## Where things live

| For                                                  | See                          |
| ---------------------------------------------------- | ---------------------------- |
| File classification (nix-path vs linux-only vs ps)   | `ARCHITECTURE.md` §12        |
| Bash 3.2 + BSD constraints (and which files)         | `ARCHITECTURE.md` §7.1, §7.2 |
| Zsh sourcing constraints                             | `ARCHITECTURE.md` §7.3       |
| Bash / PowerShell style guides                       | `ARCHITECTURE.md` §7.6, §7.7 |
| Runnable examples block (`: '...'`) format           | `ARCHITECTURE.md` §7.5       |
| ShellCheck global excludes                           | `ARCHITECTURE.md` §7.8       |
| Pre-commit hook reference (what each one does)       | `ARCHITECTURE.md` §8         |
| Test infrastructure (bats / Pester / zsh runtime)    | `ARCHITECTURE.md` §9         |
| CI workflow scenarios                                | `ARCHITECTURE.md` §10        |
| CHANGELOG discipline + SemVer policy                 | `ARCHITECTURE.md` §11        |
| Recipes ("how to add a scope / verb / hook / check") | `ARCHITECTURE.md` §6         |
| Runtime file layout (`~/.config/nix-env/` etc.)      | `ARCHITECTURE.md` §13        |

## Adding things - quick map

These are the most common contribution shapes. Each links to the full recipe in `ARCHITECTURE.md` §6.

| You want to add...      | Recipe                 |
| ----------------------- | ---------------------- |
| A new scope             | `ARCHITECTURE.md` §6.1 |
| A new phase function    | `ARCHITECTURE.md` §6.2 |
| A new `nx` verb         | `ARCHITECTURE.md` §6.3 |
| A new `nx` family file  | `ARCHITECTURE.md` §6.4 |
| A new `nx doctor` check | `ARCHITECTURE.md` §6.5 |
| A new flag              | `ARCHITECTURE.md` §6.6 |
| A new pre-commit hook   | `ARCHITECTURE.md` §6.7 |
| A new dynamic completer | `ARCHITECTURE.md` §6.8 |

## Tooling notes

- When `cspell` fails on a new word, add it to `project-words.txt` (sorted alphabetically) - that's the project dictionary. The `validate-docs-words` hook removes stale entries automatically.
- Pre-commit runner is `prek` (not `pre-commit`).
- Use `pwsh` for PowerShell 7.4+ (not `powershell`).
- Use `gh` CLI for GitHub operations.
- Before fixing a pattern globally, run `rg <pattern> .` or `git grep <pattern>` to find **all** occurrences. For bulk renames across many files, use `sed -i` instead of editing one by one. Verify with another grep afterwards.
- After a manifest change, regenerate completers: `python3 -m tests.hooks.gen_nx_completions`. The `check-nx-completions` hook will fail otherwise.

## Release process

1. Ensure all `## [Unreleased]` CHANGELOG entries are present and accurate.
2. Run `make release` - builds the tarball and prints the tag/push commands.
3. Review the tarball contents, then run the printed commands.
4. The `release.yml` workflow runs the full test matrix, generates SBOM, signs artifacts, and publishes the GitHub Release.

See `ARCHITECTURE.md` §11 for the SemVer bump policy.
