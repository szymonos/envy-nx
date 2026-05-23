# Contributing

Workflow guide for developing on this repo. For architecture, file classification, constraints, hook reference, runtime layout, and recipes ("how to add X"), see `ARCHITECTURE.md` - that is the single source of truth.

## Prerequisites

Required for any contribution:

| Tool      | Version | Purpose                                                                                                                  |
| --------- | ------- | ------------------------------------------------------------------------------------------------------------------------ |
| `bash`    | 3.2+    | Scripts (macOS system default is 3.2)                                                                                    |
| `git`     | any     | Version control                                                                                                          |
| `uv`      | latest  | Bootstraps `prek`, Python pre-commit hooks, and the docs toolchain via `make install` (replaces a global `prek` install) |
| `python3` | 3.10+   | Pre-commit hook scripts (`uv` will provide one if your system Python is older)                                           |

For running unit tests (`make test-unit`):

| Tool                               | Version | Purpose                                                                                              |
| ---------------------------------- | ------- | ---------------------------------------------------------------------------------------------------- |
| `bats`                             | 1.5+    | Bash unit tests                                                                                      |
| `pwsh`                             | 7.4+    | PowerShell scripts and Pester tests                                                                  |
| `Pester` (PS module)               | 5.6.0+  | `Install-Module -Name Pester -RequiredVersion 5.6.0 -Repository PSGallery -Scope CurrentUser -Force` |
| `zsh`                              | any     | `tests/bats/test_nx_zsh.bats` runtime smoke (auto-skipped when `zsh` is absent)                      |
| `jq`                               | any     | Used by `scopes.sh` and several bats fixtures                                                        |
| `coreutils` (`gtimeout`/`timeout`) | any     | Test-timeout helpers; macOS's BSD `coreutils` works too                                              |

For Docker smoke tests (`make test-nix`):

| Tool     | Version | Purpose                                       |
| -------- | ------- | --------------------------------------------- |
| `docker` | any     | Builds + runs the throwaway provisioning pass |

**Not needed locally** - these run inside pre-commit hooks via `prek` (which `make install` set up):

- `shellcheck`, `shfmt`, `markdownlint-cli2`, `cspell`, `ruff` - pulled by `prek` from external repos and cached in its env. You don't need them on `$PATH`.

## Quick start

```bash
make install         # `uv sync` - installs prek + Python pre-commit deps + the docs toolchain
make hooks-install   # register prek as a git hook (optional - `make lint` works without it)
make lint            # run hooks on changed files (do this before every commit)
make test-unit       # run bats + Pester unit tests in parallel (fast, no Docker)
make test            # run all tests including Docker smoke tests
make help            # list all targets
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

## Codifying learnings

When a fix or refactor teaches a generalization future contributors should know - a constraint, a non-obvious pattern, a class-of-bug to watch for - add a `Codified-Learning:` trailer to the commit body. The post-merge [`codify_learnings.yml`](.github/workflows/codify_learnings.yml) workflow scrapes those trailers and auto-appends numbered entries to [`design/lessons.md`](design/lessons.md) via a separate auto-merging PR. No hand-editing of `lessons.md` for the normal flow.

Trailer syntax:

```text
Codified-Learning: <one-line generalization>                  # tag = "general"
Codified-Learning(do-not-repeat): <one-line generalization>   # tag = "do-not-repeat"
```

Two real-world-shaped examples:

```text
fix(profile): guard prompt() against re-init under OMP

Codified-Learning: In pwsh profile scripts, never define `function Prompt`
unconditionally - the last function definition wins, so a fallback prompt
clobbers oh-my-posh's installed prompt.
```

```text
fix(pwsh): always invoke pwsh via _io_pwsh_nop, never bare pwsh

Codified-Learning(do-not-repeat): nix-built pwsh leaks LD_LIBRARY_PATH
into child processes; the wrapper clears it before invoking and falls back
to system pwsh on Coder/Ubuntu where ~/.nix-profile/bin/pwsh is absent.
```

**When to opt out.** A pre-commit hook (`check-learning-trailer`) nudges when commits touch high-leverage paths (`.assets/lib/nx_*.sh`, `nix/lib/phases/*.sh`, `tests/hooks/*.py`) without a trailer. If the commit genuinely teaches no generalization (trivial refactor, dependency bump, typo fix), add `# no-learning` anywhere in the commit body to skip the nudge.

**Where lessons live vs other ledgers.** Three durable ledgers divide the space:

| Ledger                       | Records                                          | Maintained by                                  |
| ---------------------------- | ------------------------------------------------ | ---------------------------------------------- |
| `docs/decisions.md`          | Architectural decisions (why A over B)           | Manual ADR style; PR-reviewed                  |
| `design/reviews/accepted.md` | Review-triage decisions (`defer`/`dispute`)      | Updated by `/review act` during chunked review |
| `design/lessons.md`          | Operational lessons - generalizations from fixes | Auto-populated by `codify_learnings.yml`       |

A lesson is the *rule the fix teaches*, not the fix itself (the fix is the merged code).

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
| A codified learning     | `ARCHITECTURE.md` §6.9 |

## Tooling notes

- When `cspell` fails on a new word, add it to `project-words.txt` (sorted alphabetically) - that's the project dictionary. The `validate-docs-words` hook removes stale entries automatically.
- Pre-commit runner is `prek` (not `pre-commit`).
- Use `pwsh` for PowerShell 7.4+ (not `powershell`).
- Use `gh` CLI for GitHub operations.
- Before fixing a pattern globally, run `rg <pattern> .` or `git grep <pattern>` to find **all** occurrences. For bulk renames across many files, use `sed -i` instead of editing one by one. Verify with another grep afterwards.
- After a manifest (`nx_surface.json`) change, regenerate the 9 generated artifacts: `python3 -m tests.hooks.gen_nx_completions`. The `check-nx-generated` hook will fail otherwise.

## Release process

1. Land all release content on `main` via PRs. Make sure your local `main` matches `origin/main` (`git switch main && git pull --ff-only`).
2. Promote `## [Unreleased]` entries into a versioned section: `## [X.Y.Z] - YYYY-MM-DD`. Commit + push to `main`.
3. Run `make release` from the clean `main` checkout. The target is one interactive command - it:
   - Detects the version from the latest `## [X.Y.Z]` heading in `CHANGELOG.md` (override with `make release VERSION=X.Y.Z` for hotfix builds that don't match the latest entry).
   - Validates: branch is `main`, worktree is clean, local `HEAD == origin/main`, tag `vX.Y.Z` doesn't exist locally **or** on origin (catches the "forgot to add a new release section" mistake before building).
   - Builds the tarball.
   - Prompts: `Tag vX.Y.Z at HEAD and push to origin? [y/N]`. Answer `y` to tag + push (triggers `release.yml`); anything else prints the manual `git tag` / `git push` commands and exits cleanly.
4. `release.yml` runs the full test matrix, generates SBOM, signs artifacts, and publishes the GitHub Release.

See `ARCHITECTURE.md` §11 for the SemVer bump policy.
