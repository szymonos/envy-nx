# Phase 1: Self-contained hardening

_Companion to `design/review_2026-04-23.md`. Phase 2 (enterprise integration readiness) is in `design/phase_2_enterprise_readiness.md`._

**Scope boundary.** Everything in this document can be shipped without:

- integrating any third-party enterprise system (IDP, MDM, telemetry backend, artifact store),
- breaking the "self-contained repo, disposable clone" design principle,
- requiring any paid tooling or vendor contracts.

GitHub (Actions, Releases, gh-pages) is treated as in-scope because the project already depends on it and it's free for public repos.

**Ordering note.** Documentation tone and claims rework is section §6 (last) on purpose: the re-rating in `docs/enterprise.md` only becomes honest once the hardening in §1-§5 has actually shipped. Rewriting maturity labels first would just move the dishonesty from "Strong" to "Available" without earning it.

Each section follows the same shape: **Re-review → Design → Acceptance criteria → Task checklist**.

---

## 1. Supply-chain hardening

### 1.1 Re-review

Original critique: pipes `curl | sh` from `install.determinate.systems`; no checksum pinning; defaults to `nixpkgs-unstable`; no SBOM, no signed tags.

Deeper look revealed:

- **Two curl|sh sites, not one**: `nix/lib/phases/bootstrap.sh:85` (macOS auto-install) and `.assets/provision/install_nix.sh:85` (Linux provisioning). Fixing one without the other is pointless.
- **Makefile cert interception** (`Makefile:14-19`): `openssl s_client -connect google.com:443` extracts the chain and writes `.assets/certs/ca-cert-root.crt`, which is then baked into Docker test images. This is an actively-running MITM-trust step that happens on **every `make test-nix`**, silently. There is no user confirmation, no logging of the extracted cert's subject, and no way to run the target without it.
- **Injection surface in `phase_scopes_load_existing`**: `"$CONFIG_NIX"` is interpolated into a Nix expression string (`scopes.sh:20, 41`). Low practical risk (path is user-owned), but wrong discipline.
- **`nx pin` is implemented and tested** (`tests/bats/test_nx_commands.bats:77-141`) - good. The issue is that pinning is **opt-in** not **default**; fresh installs get whatever `nixpkgs-unstable` HEAD is.
- **No `flake.lock` shipped** - intentional per ARCHITECTURE.md:348, but it means the repo itself cannot reproducibly build its own test environments.

### 1.2 Design

Layered defense. Each layer is independently useful; do them in order.

#### 1.2.1 ~~Harden the Nix installer call~~ - REJECTED

**Original proposal:** download the installer to a temp file, compute SHA-256, compare against a repo-pinned checksum, fail on mismatch.

**Why rejected:** Determinate Systems does not publish SHA-256 checksums or signatures with their releases (verified April 2025 - GitHub releases contain bare binaries only). The 19KB shell script downloaded from `install.determinate.systems` is a thin platform-detecting wrapper that fetches a ~15MB static binary per architecture at runtime - vendoring the script alone does not pin the binary. Vendoring all three platform binaries (~45MB) turns the repo into a fork of Determinate's distribution channel with the same maintenance cost as a hash-pinning workflow. Meanwhile, the installer script already pins its own binary version internally (`NIX_INSTALLER_BINARY_ROOT` points to a tagged release URL), and both call sites enforce TLS 1.2+ (`curl --proto '=https' --tlsv1.2`). Both `bootstrap.sh` and `install_nix.sh` detect existing Nix installations and skip the download entirely.

**Accepted risk:** we trust Determinate's HTTPS distribution for the one-time Nix install. Enterprises requiring stronger supply-chain controls should pre-install Nix via their approved channel (MDM, internal mirror, or manual install); all entry points detect existing installs and skip the download. See `docs/decisions.md` "Why not checksum-pin the Nix installer" for the full rationale.

#### 1.2.2 ~~Default to a pinned nixpkgs~~ - REJECTED

**Original proposal:** ship a `nix/default_pinned_rev` with a known-good nixpkgs commit SHA, seed it on first install, require `--unstable` to opt out. Monthly scheduled PR to refresh the pin.

**Why rejected:** This contradicts the project's deliberate choice of nixpkgs-unstable (see `docs/decisions.md` "Why nixpkgs-unstable, not a stable channel"). A repo-maintained pin reintroduces the staleness problem that nixpkgs-unstable solves - developers get outdated packages by default and must opt out. It also creates confusion with `nx upgrade` (upgrade to what - the same stale pin?) and generates support burden when `nx install <pkg>` fails against an old revision.

The supply-chain argument for pinning is real but narrow: a poisoned nixpkgs commit would need to survive Hydra's ~120k-package CI pipeline and the unstable channel's promotion delay. The canonical recent supply-chain attack (xz-utils) was in upstream source, not in nixpkgs - pinning nixpkgs would not have prevented it.

The existing mechanism (`nx pin set <rev>`) already serves teams that need coordinated versions. Making it the default for solo developers who benefit from current packages solves a problem they don't have while creating one they will notice (stale tools).

**Accepted trade-off:** nixpkgs-unstable with opt-in pinning via `nx pin set`. See `docs/decisions.md` for the full rationale.

#### 1.2.3 SBOM for every release

On release tag, the CI job produces:

- `sbom.spdx.json` from `nix path-info --json --recursive $(nix build --print-out-paths)` transformed via a small script in `tests/hooks/nix_closure_to_spdx.py`.
- `closure.txt` - one line per store path in the runtime closure.

Attach both to the GitHub Release. No third-party SBOM service.

#### 1.2.4 Signed releases

Sign every release artifact with GitHub's built-in `cosign` (via `sigstore/cosign-installer`). Verifiable with:

```bash
cosign verify-blob --bundle envy-nx-v1.0.0.tar.gz.bundle envy-nx-v1.0.0.tar.gz
```

Cosign keyless signing uses OIDC; no key management, no paid service, no 3rd-party infra beyond Sigstore public good infrastructure (already trusted by the Linux Foundation).

#### 1.2.5 ~~Makefile cert interception - make it explicit~~ - DEFERRED

**Original proposal:** gate `make test-nix` cert extraction on `MITM=1` flag; fail if cert file exists unexpectedly.

**Why deferred:** The Makefile cert extraction is a developer workflow for building Docker test images - end users never run it. The dev/dist separation is handled by the release tarball (§2), which includes only runtime files (nix/, .assets/lib/, .assets/config/, .assets/setup/, .assets/provision/) and excludes all developer tooling: Makefile, tests/, design/, docs/, .assets/docker/, .github/, pre-commit hooks, and CI configuration. Hardening a developer-only workflow is low priority compared to the release pipeline itself. Can be revisited as a contributor-experience improvement after v1.0.

### 1.3 Remaining task

- [x] Fix `_io_nix_eval` callers in `scopes.sh` - pass path via `builtins.getEnv` instead of interpolating into the expression.

SBOM generation (§1.2.3) and cosign signing (§1.2.4) are steps in the release workflow and are consolidated into §2 below.

---

## 2. Release pipeline and v1.0 readiness

### 2.1 Re-review

Original critique: no tags, no releases, CHANGELOG is `[Unreleased]` only, no release tarball workflow, no `VERSION` file in repo.

Deeper look revealed:

- **`install_record.sh:30-42`** already supports both `git describe` and `VERSION` file fallback, plus a `source: "git" | "tarball"` field - the mechanism is ready; the producer workflow isn't.
- **`design/implementation_plan.md`** already describes a release tarball builder (Phase 1, ~1.5 days). My proposal extends rather than replaces that plan.
- **No `.github/workflows/release.yml`** exists.
- **Integration tests gate on labels** (`test:linux`, `test:macos`) - this is reasonable for PRs, but releases should run the full matrix unconditionally.
- **mkdocs docs** are published via `docs-gh-pages.yml`; release version currently isn't threaded into the site.

### 2.2 Design

The release pipeline serves two purposes: (1) provide a versioned, verifiable distribution artifact that does not require git, and (2) establish release hygiene so every shipped version is tested, documented, and traceable.

#### 2.2.1 Release tarball (`.assets/tools/build_release.sh`)

Packs a minimal **runtime-only** tarball from the repo. The tarball is the distribution artifact - it contains everything needed to provision a workstation and nothing else.

**Included** (runtime files only):

- `nix/` - setup orchestrator, flake, scopes, phase libraries, configure scripts
- `.assets/lib/` - nx CLI, scopes engine, doctor, profile block management
- `.assets/config/` - shell aliases, prompt themes, tool configs
- `.assets/setup/` - post-install user setup (PS modules, zsh plugins)
- `.assets/provision/` - system-scope installers (nix, pwsh, docker, copilot)
- `wsl/` - WSL orchestration scripts
- `LICENSE`, `README.md`, `VERSION`

**Excluded** (developer tooling):

- `.git/` - version control history
- `tests/` - bats, pester, pre-commit hooks
- `design/` - architecture reviews, implementation plans
- `docs/` - mkdocs source (published separately via gh-pages)
- `.assets/docker/` - Docker test images
- `.github/` - CI workflows, issue templates
- `Makefile` - developer build targets
- `modules/` - PowerShell dev modules
- `.claude/`, `.pre-commit-config.yaml`, `.editorconfig` - dev tooling config

Stamps `VERSION` from `git describe --tags` (e.g., `1.0.0`). Generates `CHECKSUMS.sha256` for the tarball.

**Why a tarball, not just git clone:**

- **No git required.** On a bare macOS or fresh WSL, git may not exist yet. The tarball needs only `curl` + `tar` (shipped with every OS). This solves the bootstrapping problem - the tool that installs git cannot require git.
- **Enterprise distribution.** Artifact repositories (Artifactory, Nexus) distribute tarballs, not git repos. IT teams can download, verify the signature, upload to their internal store - no git access needed on developer machines.
- **Deterministic version.** A tagged tarball is immutable. `git clone` gives HEAD, which may change between clone and setup run.
- **Signed provenance.** With cosign, the tarball proves "this was built by CI from commit X." A git clone only proves "this is what's on GitHub right now."

Git clone remains the primary path for developers and contributors. The tarball is for distribution to end users and enterprise artifact stores.

#### 2.2.2 Release workflow (`.github/workflows/release.yml`)

Triggered on `v*` tags. Single workflow, six steps:

1. **Test.** Run full Linux + macOS matrix with `--all --unattended` scopes (not the smoke subset - the real thing). Release is blocked if any test fails.
2. **Build.** Run `.assets/tools/build_release.sh` to produce the tarball + `CHECKSUMS.sha256`.
3. **SBOM.** Generate `sbom.spdx.json` from `nix path-info --json --recursive` (the Nix closure) transformed via `tests/hooks/nix_closure_to_spdx.py` (Python stdlib only). Also emit `closure.txt` - one line per store path, human-readable. This is the complete bill of materials for everything Nix installs.
4. **Sign.** Cosign keyless signing (via `sigstore/cosign-installer`) of tarball and SBOM using GitHub's OIDC identity. No keys to manage, no secrets to rotate. Produces `.bundle` files verifiable with `cosign verify-blob`.
5. **Publish.** Create GitHub Release with attached: tarball, CHECKSUMS, SBOM, closure list, cosign bundles, rendered CHANGELOG excerpt for the tag.
6. **Docs.** Refresh mkdocs site with the new version number in the footer.

#### 2.2.3 Tarball smoke test

New matrix entry in `test_linux.yml`: builds the tarball, extracts to a temp directory (no `.git`), runs `nix/setup.sh --shell`, asserts `install.json.source == "tarball"` and `install.json.version` matches the tag. Validates the tarball install path that git-clone-based CI doesn't cover.

#### 2.2.4 Release discipline

- **CHANGELOG enforcement.** Pre-commit hook (`check-changelog`) fails if a PR changes any runtime file (`nix/`, `.assets/`, `wsl/`) without adding a line under `## [Unreleased]`. Bypass via label `skip-changelog`.
- **Semantic versioning** codified in `CONTRIBUTING.md`:
  - MAJOR: breaking config.nix layout, removed `nx` subcommand, removed scope.
  - MINOR: new scope, new `nx` subcommand, new flag.
  - PATCH: bug fix, internal refactor, dep bump, doc change.
- **`make release` target.** Checks for clean worktree, bumps CHANGELOG, creates annotated tag. Does NOT push by default - prints the command for the maintainer to run. Avoids accidental releases.
- **Version skew detection.** `nx doctor` gains a `--version-skew` check that warns if `install.json.version` is older than the latest GitHub release (via `gh api`; silent no-op on air-gapped networks).

### 2.3 Acceptance criteria

- Cutting `v1.0.0` produces a GitHub Release with: tarball, `CHECKSUMS.sha256`, `sbom.spdx.json`, `closure.txt`, cosign bundles, rendered CHANGELOG excerpt.
- Installing from the tarball (no `.git`) works end-to-end; `install.json.source == "tarball"`, `install.json.version == "1.0.0"`.
- Mkdocs site footer shows `v1.0.0`.
- Adding a runtime change without a CHANGELOG entry fails `make lint`.
- `make release` on a dirty worktree fails with a clear error.

### 2.4 Tasks

- [x] Write `.assets/tools/build_release.sh` (bash 3.2-safe): pack runtime-only tarball, stamp VERSION, generate CHECKSUMS.sha256.
- [x] Write `tests/hooks/nix_closure_to_spdx.py` (Python stdlib only): transform `nix path-info --json` to SPDX 2.3 JSON.
- [x] Add `.github/workflows/release.yml`: test → build → SBOM → cosign sign → publish → docs refresh.
- [x] Add tarball smoke test job to `test_linux.yml`: install from tarball, assert `install.json.source == "tarball"`.
- [x] Extend `Makefile` with `release` target (clean worktree check, CHANGELOG bump, annotated tag, print push command).
- [x] Write `tests/hooks/check_changelog.py`; wire into pre-commit.
- [x] Add `CONTRIBUTING.md` section on semver rules.
- [x] Implement `nx doctor --version-skew`; silent no-op on network failure.
- [x] Backfill CHANGELOG: create `## [1.0.0-rc1] - 2026-04-25` header; move entries under it.
- [x] Update README install snippet to offer both `git clone` and `curl -LO <tarball>` paths.

---

## 3. Architecture refinements

### 3.1 Re-review

Original critique: `SC2154` disabled in multiple files; `_on_exit` reads six globals; phase `# Reads:/Writes:` comments are docs not enforced.

Deeper look revealed:

- **Six files disable SC2154**: `nix/setup.sh`, `nix/lib/phases/configure.sh`, `nix/lib/phases/scopes.sh`, `nix/lib/phases/summary.sh`, `nix/lib/phases/nix_profile.sh`, `.assets/scripts/linux_setup.sh`.
- **Global namespace is mixed-case by convention**: `_IR_*` (uppercase) for install_record inputs, `_ir_*` (lowercase) for setup.sh trap state, `_scope_set` (underscore-prefixed lower), `sorted_scopes` (plain lower), `VALID_SCOPES` (uppercase from scopes.sh). No document spells out which is which.
- **`_on_exit`** (`nix/setup.sh:54-67`) reads `sorted_scopes`, `allow_unfree`, `_mode`, `platform`, `_ir_phase`, `_ir_error`, `_ir_skip` - none are declared or defaulted locally. Any rename in a phase file silently breaks the trap.
- **`phase_summary_detect_mode` called twice** (`setup.sh:83,124`) - deliberate (mode differs before vs after scope resolution) but uncommented.
- **`phase_platform_run_hooks`** uses `NIX_ENV_PHASE` env var but the list of phase-exposed vars is only in `ARCHITECTURE.md:244-252` - not in the hooks directory README (there isn't one).
- **`_io_*` wrappers** are good but incomplete: `_io_nix_eval` has a distinct wrapper, `_io_run` is the catch-all; `docker` and `gh` are called directly in configure scripts, not wrapped.

### 3.2 Design

**Tighten the phase contract without inventing a DSL.** Each item was evaluated against the actual code; several were rejected or slimmed down where the proposed fix was heavier than the problem.

#### 3.2.1 ~~Single canonical globals list (`nix/lib/globals.sh`)~~ - SLIMMED DOWN

**Original proposal:** Create `nix/lib/globals.sh` with every cross-phase global declared + `_globals_dump` for test introspection. Source it before phase files.

**What the code shows:** `_on_exit` reads 7 variables; 4 (`_ir_error`, `sorted_scopes`, `_mode`, `platform`) are never declared or defaulted - they're assumed to exist because a phase ran earlier. If a phase fails before `phase_platform_detect`, `platform` is unset and `install.json` gets garbage. The file-level `SC2154` blanket suppressions also hide new typos.

**Decision:** Default the 4 undeclared trap variables directly in `setup.sh` (next to the existing `_ir_phase="bootstrap"` and `_ir_skip=false` declarations). Then narrow each file's `SC2154` to specific variables or remove it entirely. No new file needed - the phase files already document their contracts via `# Reads: / # Writes:` headers.

#### 3.2.2 ~~Naming convention doc (`nix/lib/README.md`)~~ - SKIP (documented in ARCHITECTURE.md instead)

**Original proposal:** Write `nix/lib/README.md` documenting `_IR_*`, `_ir_*`, `_io_*`, `phase_*` conventions.

**What the code shows:** The naming is already very consistent across the entire codebase. The exploration found zero naming inconsistencies. `_IR_*` for install record exports, `_ir_*` for trap state, `_io_*` for wrappers, `phase_*` for public functions - all self-evident from the code.

**Decision:** Skip a separate README. The naming convention table and wrapper boundary design are documented in `ARCHITECTURE.md` under "Phase library and test stubs" so future reviewers can see the rationale without proposing a fix for something that already works.

#### 3.2.3 ~~Machine-checkable `# Reads: / # Writes:` (`check_phase_contract.py`)~~ - REJECTED

**Original proposal:** Pre-commit hook that parses phase headers, statically identifies variable reads/writes, and fails if the header lies.

**Why rejected:** Statically parsing bash variable reads/writes is fundamentally unreliable. The hook would need to handle `$(...)` subshells, `${foo:-default}` expansions, indirect references, variables read by sourced libraries (e.g. `sorted_scopes` populated by `sort_scopes()` from `scopes.sh`), and the difference between `local` and global variables. The design doc acknowledged this: "heuristic parse, no real AST - good enough for bash." In practice, "good enough" heuristic parsers for bash generate false positives that train developers to suppress the hook. ShellCheck itself - with years of development - still doesn't fully solve this.

The manual `# Reads: / # Writes:` headers are valuable documentation. They're maintained by the same person writing the phase code. A flaky automated checker adds noise without catching real bugs.

#### 3.2.4 ~~Expand `_io_*` coverage~~ - MINIMAL

**Original proposal:** Add `_io_gh`, `_io_docker`, `_io_jq`, `_io_git` to `io.sh`. Migrate all call sites.

**What the code shows:** The direct `gh`, `git`, `curl` calls are in configure scripts (`nix/configure/*.sh`), which are already called via `_io_run` from the phase layer. Adding `_io_gh` inside `gh.sh` would require tests to stub at two levels (both `_io_run` for the script and `_io_gh` for the command) for no gain. The only exception is `nix_profile.sh:92` calling `git config` directly - a phase file bypassing the wrapper pattern.

**Decision:** Fix the one `git config` call in `nix_profile.sh` by routing through `_io_run`. Skip wrapping commands inside configure scripts - they're already wrapped at the call boundary. The wrapper boundary design is documented in `ARCHITECTURE.md`.

#### 3.2.5 Comment the twin `phase_summary_detect_mode` call

**What the code shows:** Called at `setup.sh:83` (after arg parsing) and `setup.sh:124` (before summary print). The second call is necessary because scope removal during the scopes phase can change the effective mode. A reader sees the same function called twice and wonders if it's a bug.

**Decision:** Add a one-line comment before the second call. Don't rename - the function is the same function, intentionally idempotent.

#### 3.2.6 ~~Eliminate `_io_nix_eval` path interpolation~~ - DEFERRED

**What the code shows:** Two call sites in `scopes.sh` interpolate `$CONFIG_NIX` into a Nix expression: `import '"$CONFIG_NIX"'`. `CONFIG_NIX` is `~/.config/nix-env/config.nix` (user-owned), so the injection risk is "the user attacks themselves."

The alternatives all have trade-offs: `--argstr` doesn't work with `nix eval --expr`; `builtins.getEnv` requires `--impure` (already used) but trades string interpolation for environment variable injection - arguably the same trust level; `--file` requires writing a separate `.nix` file.

**Decision:** Defer. Low risk, no clean alternative. Do it opportunistically if touching `scopes.sh` for other reasons.

### 3.3 Acceptance criteria

- `_on_exit` trap variables (`_ir_error`, `sorted_scopes`, `_mode`, `platform`) have defaults in `setup.sh`.
- File-level `SC2154` suppressions in `nix/lib/phases/` are narrowed to specific variables or removed.
- The `git config` call in `nix_profile.sh` goes through `_io_run`.
- Second `phase_summary_detect_mode` call has a comment explaining why.
- Naming conventions and wrapper boundary documented in `ARCHITECTURE.md`.

### 3.4 Tasks

- [x] Add defaults for undeclared trap variables (`_ir_error`, `sorted_scopes`, `_mode`, `platform`) in `setup.sh`.
- [x] Narrow or remove `shellcheck disable=SC2154` in phase files; justify remaining ones with inline comments.
- [x] Route the `git config` call in `nix_profile.sh:92` through `_io_run`.
- [x] Add comment before second `phase_summary_detect_mode` call in `setup.sh`.
- [x] Document naming conventions and wrapper boundary in `ARCHITECTURE.md`.

---

## 4. Test and quality gaps

### 4.1 Re-review

Original critique: WSL path not integration-tested; tarball install path untested; air-gapped flow untested.

Deeper look revealed:

- **283 bats + 136 Pester** - solid. Coverage gaps aren't about quantity, they're about specific paths:
  - Tarball install (`source: "tarball"` in `install.json`) - only triggered without `.git`, which CI never does.
  - `install_record.sh` fallback path (lines 89-103, when jq unavailable) - only used during initial bootstrap.
  - Cosign verification of a fresh release (future §1.2.4).
  - MITM probe success+failure paths in `phase_nix_profile_mitm_probe`.
  - Uninstaller `--dry-run` vs real mode diff.
  - `nx overlay status` with intentionally mutated installed files.
- **WSL path: 136 Pester `It` blocks** cover orchestration logic against mocked `wsl.exe`. Not equivalent to e2e, but better than I credited in the initial review. The real gap is: no test boots an actual WSL2 guest.
- **Docker smoke test** (`.assets/docker/Dockerfile.test-nix`) covers the happy path but takes ~3-5 min; isn't run in pre-commit.
- **No mutation testing** - tests prove the code does what tests expect, not that tests would catch regressions.
- **No property-based tests** on scope dependency resolution (`resolve_scope_deps`), which is the most logic-dense piece in `.assets/lib/scopes.sh`.

### 4.2 Design

Each proposal evaluated against the actual codebase. Several were rejected or slimmed down.

#### 4.2.1 Tarball install integration test

New `test_linux.yml` matrix entry: `tarball`. Builds the tarball with `.assets/tools/build_release.sh`, extracts to a temp dir with `.git` removed, runs `nix/setup.sh --shell`, asserts `install.json.source == "tarball"` and `install.json.version` matches the tag. Real gap: CI always runs from a git checkout, so the tarball install path is never exercised.

#### 4.2.2 ~~Air-gapped smoke test~~ - SLIMMED DOWN

**Original proposal:** `tests/scripts/airgap_probe.sh` with iptables firewall rules in a labeled CI job.

**What the code shows:** `nix_profile.sh:37-45` already handles network failure gracefully - `nix flake update` failures produce a warning and continue with the existing lock file. The error path is implemented; it's just not tested.

**Decision:** Add a bats unit test stubbing `_io_nix` to fail, asserting the warning message and non-fatal exit. Skip the iptables CI job - it adds complexity for a scenario already handled in code.

#### 4.2.3 install_record.sh jq fallback test

The fallback at `install_record.sh:89-103` writes JSON via heredoc when jq is unavailable. This is the bootstrap path - if `phase_bootstrap_install_jq` fails, the exit trap still needs valid JSON. No test covers this. Worth doing: stub jq out of PATH, call `write_install_record`, validate output with `python3 -m json.tool`.

#### 4.2.4 ~~WSL lima-based integration~~ - SKIP

**Original proposal:** Linux CI job running lima to simulate WSL2 guest.

**Why skipped:** 66 Pester tests already cover orchestration logic with mocked `wsl.exe`. The interesting bugs are in real `wsl.exe` behavior (encoding, path translation, distro lifecycle) which Lima can't replicate. A real Windows runner would help but is expensive self-hosted infra. The mocked tests are the right trade-off for a project this size.

#### 4.2.5 ~~Property tests for scope resolver~~ - SLIMMED DOWN

**Original proposal:** 1000 randomized scope sets testing idempotency and order stability.

**What the code shows:** The resolver has 7 dependency edges total. `test_scopes.bats` already has 7 targeted tests covering each edge. Randomized testing exercises the same 7 edges repeatedly.

**Decision:** Add one explicit idempotency test - call `resolve_scope_deps` twice, assert no duplicates. That's the actual untested invariant.

#### 4.2.6 ~~Coverage snapshot~~ - SKIP

**Original proposal:** `tests/hooks/coverage_snapshot.py` counting phase function test coverage, PR comment on reductions.

**Why skipped:** 11/32 phase functions have direct bats tests (34%). Sounds alarming but is misleading - many untested phases are thin wrappers (`phase_bootstrap_check_root` is 3 lines checking `$EUID`). CI integration tests cover them end-to-end. A coverage bot creates noise that developers suppress.

#### 4.2.7 Uninstaller --dry-run test

`--dry-run` is implemented (prints "would remove" instead of removing) but untested. The CI tests real `--env-only`. A test comparing `--dry-run` output against what `--env-only` actually removes catches regressions when new cleanup steps are added.

#### 4.2.8 MITM probe test

`phase_nix_profile_mitm_probe` was just refactored to probe-first on all platforms. The only existing test stubs `_io_curl_probe` to return 0 (success). No test covers the failure path: probe fails → `cert_intercept` → `build_ca_bundle`. Given the recent change, a test for the failure → intercept → bundle flow catches regressions.

### 4.3 Acceptance criteria

- A tarball built from the current worktree can install on a clean Ubuntu container; `install.json` reflects `source: "tarball"`.
- `install_record.sh` fallback path (no jq) has at least one bats test producing valid JSON.
- `resolve_scope_deps` idempotency is explicitly tested.
- `nix/uninstall.sh --dry-run` has a test validating non-destructive output.
- `phase_nix_profile_mitm_probe` failure path has a test asserting cert interception is triggered.
- Flake update failure path has a test asserting non-fatal warning.

### 4.4 Tasks

- [x] Add `tarball` matrix entry to `test_linux.yml`: build tarball, extract without `.git`, run setup, assert `install.json.source == "tarball"`.
- [x] Add bats test for flake-update failure path: stub `_io_nix` to fail, assert warning and non-fatal exit.
- [x] Add bats test for `install_record.sh` jq fallback: stub jq out of PATH, call `write_install_record`, validate JSON.
- [x] Add idempotency test to `test_scopes.bats`: call `resolve_scope_deps` twice, assert no duplicates.
- [x] Add test for `nix/uninstall.sh --dry-run` producing non-destructive output.
- [x] Add test for `phase_nix_profile_mitm_probe` failure path: stub curl to fail, assert `cert_intercept` and `build_ca_bundle` are called.

---

## 5. Minor items (quick wins)

### 5.1 Re-review corrections

My initial review was wrong on three points:

- **`scripts_egsave.ps1`** is **not** unexplained. It has comment-based help and uses `Invoke-ExampleScriptSave` from the project's own `modules/SetupUtils/`. Its real problem: it's absent from `CONTRIBUTING.md`, `ARCHITECTURE.md`, and the Makefile. A new contributor has no way to discover it when adding `: '...'` example blocks to new scripts - which `CONTRIBUTING.md` requires.
- **`nx pin`** IS covered by tests (`tests/bats/test_nx_commands.bats:77-141`). My Phase 1 proposal to make pinning the default (§1.2.2) is additive, not corrective.
- The CHANGELOG already points to `docs/proxy.md` correctly; earlier commits fixed the broken link.

### 5.2 Design

Each item evaluated against the codebase.

#### 5.2.1 Move `scripts_egsave.ps1` → `.assets/scripts/scripts_egsave.ps1`

**WORTH DOING - mechanical but not trivial.** The script sits at the repo root with an awkward name. `.assets/scripts/` already contains utility scripts (`linux_setup.sh`, `modules_update.ps1`, font installers). Moving it there is consistent.

Impact: 51 references across 17 PS1 files (each has 3 example lines like `.assets/scripts/scripts_egsave.ps1 wsl/wsl_setup.ps1`). The script uses `Push-Location $PSScriptRoot` and `Import-Module (Resolve-Path './modules/SetupUtils')` - both assume repo root, so the module import path needs adjusting. A single `sed`/PowerShell replace handles the bulk of the reference updates.

#### 5.2.2 Add `make egsave` target

**WORTH DOING - trivial.** Calls `.assets/scripts/scripts_egsave.ps1` with a pwsh-missing fallback message. Discoverable entry point for contributors.

#### 5.2.3 Cross-link from CONTRIBUTING.md

**WORTH DOING - trivial.** The "Runnable examples block" section (line 91) describes the format but never mentions the tool that generates them. One sentence + `make egsave` reference.

#### 5.2.4 ~~Classify `scripts/` in ARCHITECTURE.md~~ - MOOT

**No longer needed.** `build_release.sh` was moved to `.assets/tools/` (developer-only, excluded from tarball). No top-level `scripts/` dir exists.

#### 5.2.5 ~~Audit CHANGELOG.md~~ - MINIMAL

**What the file shows:** CHANGELOG is comprehensive. `nx overlay` (line 32-33) and hooks (line 30) are already listed. Missing: `nx pin` subcommands, `--allow-unfree` flag. Not worth a dedicated audit - add these when touching the file for other reasons.

### 5.3 Tasks

- [x] Move `scripts_egsave.ps1` → `.assets/scripts/scripts_egsave.ps1`; fix `Push-Location`/module import path.
- [x] Update all 51 `.assets/scripts/scripts_egsave.ps1` references across 17 PS1 files.
- [x] Add `make egsave` target (with pwsh-missing fallback).
- [x] Add one sentence + `make egsave` reference to CONTRIBUTING.md "Runnable examples block".
- [x] ~~Add `scripts/` to ARCHITECTURE.md~~ - moot: `build_release.sh` moved to `.assets/tools/`.
- [x] Add missing `nx pin` and `--allow-unfree` entries to CHANGELOG.

---

## 6. Documentation tone and claims rework

**This section is deliberately last.** The re-rating is only honest once §1-§5 have actually shipped: supply-chain hardening earns a real "Available" on security; a tagged v1.0 release earns a real "Available" on release hygiene; architecture refinements earn a real "Available" on maintainability. Doing this section first would just rename the dishonesty.

### 6.1 Re-review

Original critique: `docs/enterprise.md` rates itself "Strong" on 7 of 9 dimensions; framing like "MDM integration: Ready (not included)" is marketing-speak for "not integrated".

Deeper look revealed:

- **The doc opens with "An honest assessment"** (`docs/enterprise.md:3`) while giving itself Strong on Code quality, Architecture, Cross-platform, Documentation, Corporate proxy, Extensibility, and Upgrade/rollback. Some of these are legitimate (corporate proxy, architecture); others are self-graded ("Documentation: Strong") without a rubric.
- **README claim "412 unit tests"** (`README.md:38`) is factually wrong. Actual count: 292 bats + 66 Pester = **358 tests**. The same wrong number appears in `docs/enterprise.md` and `docs/index.md`.
- **Two architecture docs**: root `ARCHITECTURE.md` (622 lines) and `docs/architecture.md` (177 lines). The latter explicitly links to the root as "full reference" - this is intentional hierarchy, not accidental drift. But anything duplicated between them will diverge.
- **CHANGELOG has only `[Unreleased]`** - zero released versions, yet public docs use assertive present-tense. After §2 ships, the present-tense claims become earned.
- **No rubric** defines what "Strong" means in the maturity table.

### 6.2 Design

Each proposal evaluated against actual effort and value.

#### 6.2.1 Maturity rubric and re-rating

**WORTH DOING - this is the core of §6.** Replace "Strong" with Available/Partial/Stub/Missing. Define the scale at the top of `docs/enterprise.md`. Re-rate each dimension with a one-line citation to a commit, workflow, or test file. 7 "Strong" ratings + 3 qualified ratings = 10 rows to re-evaluate. This is the bulk of the effort.

#### 6.2.2 ~~Auto-generated test count (`gen_stats.py`)~~ - SLIMMED DOWN

**Original proposal:** Pre-commit hook counting tests, outputting `docs/_generated/stats.md`, included via mkdocs snippets.

**Why slimmed down:** A pre-commit hook + mkdocs snippet pipeline to keep a single number current is over-engineered. The number is already wrong (358, not 412) and will rot again the moment a test is added. Simpler fix: drop the hardcoded count from README, enterprise.md, and index.md. Replace with qualitative language ("Comprehensive bats and Pester test suites, CI-validated on macOS and Linux") that doesn't go stale.

#### 6.2.3 Merge architecture docs

**WORTH DOING - minimal approach.** `docs/architecture.md` is an intentional condensed summary, not accidental drift. Make it a thin pointer with no duplicated content - anything it duplicates will diverge. Keep root `ARCHITECTURE.md` as the canonical source.

#### 6.2.4 Rewrite docs/index.md opening

**WORTH DOING - low effort.** The opening is a problem-statement pitch. After v1.0, state what the tool does.

#### 6.2.5 Add Limitations section

**WORTH DOING.** No limitations section exists. Post-Phase 1 honest state: WSL not e2e-tested, single-maintainer project, no fleet telemetry collector, no MDM packaging.

#### 6.2.6 ~~`check-claims` pre-commit hook~~ - SKIP

**Original proposal:** Hook grepping docs for banned marketing phrases.

**Why skipped:** Overkill for a single-maintainer project. The fix is writing honest docs (§6.2.1), not policing word choice with automation.

#### 6.2.7 Per-row citation column

**WORTH DOING - forces honesty.** Each maturity rating backed by a specific commit, workflow, or test file. Can be combined with §6.2.1.

### 6.3 Acceptance criteria

- `docs/enterprise.md` has zero occurrences of "Strong" / "Weak"; uses Available/Partial/Stub/Missing.
- A rubric table at the top defines the four levels unambiguously.
- Hardcoded test count removed from README, enterprise.md, and index.md.
- `docs/architecture.md` is a thin pointer to root `ARCHITECTURE.md` with no duplicated content.
- `docs/index.md` has a Limitations section reflecting post-Phase 1 reality.
- Every maturity label in `docs/enterprise.md` is justified with a one-line citation.

### 6.4 Tasks

- [x] Define Available / Partial / Stub / Missing rubric at top of `docs/enterprise.md`.
- [x] Re-rate all 10 dimensions using the rubric; add per-row citation column.
- [x] Replace "MDM integration: Ready (not included)" → "MDM integration: Stub".
- [x] Replace "Fleet telemetry: Scaffold only" → "Fleet telemetry: Stub".
- [x] Replace "Policy enforcement: Extension point" → "Policy enforcement: Missing".
- [x] Re-rate security, release hygiene, and maintainability citing shipped §1-§3 work.
- [x] Drop hardcoded "412 unit tests" from README.md, docs/enterprise.md, docs/index.md.
- [x] Reduce `docs/architecture.md` to a thin pointer (no duplicated content).
- [x] Rewrite `docs/index.md` opening to earned present-tense.
- [x] Add Limitations section to `docs/index.md`.

---

## Effort and sequencing

| § | Block                                                      | Est. effort    | Blocks             |
| - | ---------------------------------------------------------- | -------------- | ------------------ |
| 5 | Minor items (egsave move, make target, docs)               | 0.5 d          | nothing            |
| 3 | Architecture refinements (defaults, SC2154, comment)       | ~~0.5 d~~ done | §4                 |
| 4 | Test/quality gaps (6 targeted tests, slimmed from 8)       | 0.5 d          | §2                 |
| 1 | Supply-chain hardening (remaining: `_io_nix_eval` cleanup) | 0.5 d          | §2                 |
| 2 | Release pipeline / v1.0                                    | ~~2 d~~ done   | §6                 |
| 6 | Documentation tone rework (rubric, slimmed from 15 tasks)  | ~~1 d~~ done   | §1, §2, §3 shipped |
|   | **Total remaining**                                        | **0 dev-days** |                    |

Recommended order: §5 → §4 → §1 → §2 (tag v1.0.0) → §6 (re-rate `docs/enterprise.md` against the now-earned state).

Each section is independently mergeable. Cutting v1.0.0 is the exit criterion for §1-§5; §6 is the post-release honesty pass and closes Phase 1. Phase 2 (enterprise integration readiness) starts against a tagged, signed, reproducible release with honest maturity labels.
