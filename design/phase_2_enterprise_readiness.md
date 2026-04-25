# Phase 2: Enterprise integration readiness

_Companion to `design/review_2026-04-23.md` and `design/phase_1_self_contained.md`. This document assumes Phase 1 is shipped (v1.0.0 tag, signed releases, hardened supply chain, honest docs)._

**Scope boundary.** Phase 2 is about making the upstream repo a **good citizen for downstream enterprise forks** without:

- integrating any specific IDP, MDM, telemetry backend, or artifact store,
- shipping any proprietary or vendor-specific code,
- compromising the "works standalone on a laptop" property.

The goal is a set of **stable, documented extension seams** such that an org fork (or third party) can add IDP catalog entries, signed overlays, fleet telemetry, MDM packaging, and policy enforcement **without patching or forking the core code**. Every seam is either a directory the core reads, an env var the core honours, a JSON contract the core emits, or a hook the core invokes.

The existing `design/enterprise_notes.md` is the reference model; this document is the **implementation plan for the seams** that the notes rely on. The notes describe what an enterprise fork will build; this plan delivers the contracts that make that cheap.

Each section follows the same shape: **Re-review → Design → Acceptance criteria → Task checklist**.

---

## 1. Overlay distribution contract

### 1.1 Re-review

`phase_platform_run_hooks` and `NIX_ENV_OVERLAY_DIR` already exist (`nix/lib/phases/platform.sh:31-49`). The overlay directory is discovered; `.nix` files under `scopes/` are listed in the summary. But:

- **Nothing in `nix/flake.nix` actually consumes the overlay scopes.** Listing is not loading.
- **No `overlay.yaml` metadata schema.** An org overlay dropped into `$OVERLAY_DIR` has no way to declare its name, version, or minimum core version - so the core can't refuse an incompatible overlay.
- **No verification of overlay integrity.** Dropped-in scopes are trusted without signature checks. `enterprise_notes.md:30-35` pushes this to the fork; that's fine, but the **seam** for verification (a hook point that runs before overlay consumption) doesn't exist yet.
- **User-tier overlay writable path is implicit** (`$ENV_DIR/local`). Never documented as a public contract.
- **`docs/customization.md`** exists but doesn't yet describe the overlay contract at the level a fork would need to rely on it.

### 1.2 Design

Promote the overlay from a "skeleton" into a **documented three-tier contract** that the core reads and respects, without knowing anything about how tiers are distributed.

<!-- markdownlint-disable MD029 -->

1. **Tier discovery** (no semantic change, just documented order):

| Tier | Path resolution                                                         | Writable?    |
| ---- | ----------------------------------------------------------------------- | ------------ |
| base | this repo                                                               | no           |
| org  | `$NIX_ENV_ORG_OVERLAY_DIR`, fallback `/etc/nix-env/overlay` if readable | no (to user) |
| user | `$NIX_ENV_USER_OVERLAY_DIR`, fallback `$ENV_DIR/local`                  | yes          |

   `NIX_ENV_OVERLAY_DIR` (legacy) is treated as an alias for the org tier with a deprecation warning.

2. **`overlay.yaml` schema** (optional; absent overlay = "unnamed, no constraints"):

   ```yaml
   name: acme-platform
   version: 2.3.1
   min_core_version: 1.0.0
   max_core_version: 2.0.0   # optional
   scopes:                   # informational; real scopes are *.nix files
     - acme_baseline
     - acme_secrets
   ```

   The core parses `overlay.yaml` (python stdlib yaml isn't stdlib - use a tiny bash YAML shim or require `yq` for overlay-aware features; absence = skip).

3. **Wire overlay scopes into the flake.** Extend `nix/flake.nix` to read `$NIX_ENV_ORG_OVERLAY_DIR/scopes` and `$NIX_ENV_USER_OVERLAY_DIR/scopes` as additional import roots. Missing dirs = no-op.

4. **Pre-overlay verification hook**: `$ENV_DIR/hooks/pre-overlay.d/`. Runs before overlay scopes are loaded. If any hook exits non-zero, overlay is rejected for that run. This is the seam where a fork plugs in signature verification, minisign checks, or policy gates - none of which live in the core.

5. **`nx overlay` subcommand** already exists (per tests). Extend with:
   - `nx overlay info` - prints tiers, their paths, their `overlay.yaml` metadata, their scope count.
   - `nx overlay verify` - runs pre-overlay hooks only, without installing.

6. **Reserve env vars**, documented but not wired to anything in upstream:
   - `NIX_ENV_ORG_OVERLAY_URL` - fetch target (consumed by fork's `nx overlay fetch`).
   - `NIX_ENV_ORG_OVERLAY_PUBKEY` - verification material (consumed by fork's pre-overlay hook).

<!-- markdownlint-enable MD029 -->

### 1.3 Acceptance criteria

- `nix/setup.sh --help` lists `NIX_ENV_ORG_OVERLAY_DIR` and `NIX_ENV_USER_OVERLAY_DIR`.
- Dropping a scope file into `$NIX_ENV_ORG_OVERLAY_DIR/scopes/foo.nix` makes it available to `nix/setup.sh --foo` without touching the core.
- `overlay.yaml` with `min_core_version` greater than running core causes a documented refusal, not a silent crash.
- `nx overlay info` prints metadata for all tiers.
- `hooks/pre-overlay.d/*.sh` are executed in lexical order before overlay consumption; non-zero exit aborts overlay load without aborting the base install.
- `docs/customization.md` documents the full contract (paths, env vars, schema, hook lifecycle, version constraints).
- A test fixture installs a fake overlay and asserts end-to-end behaviour.

### 1.4 Tasks

- [ ] Split `NIX_ENV_OVERLAY_DIR` into `NIX_ENV_ORG_OVERLAY_DIR` + `NIX_ENV_USER_OVERLAY_DIR` in `platform.sh`; keep legacy var as deprecated alias with warning.
- [ ] Extend `nix/flake.nix` to import scopes from org + user overlay paths when present.
- [ ] Write `nix/lib/phases/overlay.sh` (or extend platform.sh) with `phase_overlay_load_metadata` (parses `overlay.yaml`) and `phase_overlay_check_compat` (version constraints).
- [ ] Add `pre-overlay.d` hook point invocation before overlay scope load.
- [ ] Implement `nx overlay info` + `nx overlay verify` subcommands.
- [ ] Document the full overlay contract in `docs/customization.md` (with a worked minimal org overlay example).
- [ ] Add bats tests: metadata parse, version refusal, pre-overlay hook gating, scope discovery.
- [ ] Update `ARCHITECTURE.md` overlay section to describe the three-tier contract.

---

## 2. Hook lifecycle contract

### 2.1 Re-review

Hooks exist (`pre-setup.d`, `post-setup.d` invoked from `nix/setup.sh:88,117`). But:

- **No README in the hook directories.** A fork writing hooks has no stable reference for the contract.
- **`NIX_ENV_PHASE` is exported but which variables are exposed to hooks is only in `ARCHITECTURE.md:244-252`.** Not stable API yet.
- **No documented error semantics.** Does `set -e` propagate? Does a failing hook abort install? (Currently: `source "$hook"` under `set -e` in setup.sh, so yes - but undocumented and accidentally depended on.)
- **No ordering contract across tiers.** `enterprise_notes.md:98` mentions "base -> org -> user, lexical within tier" as a goal; no code implements it.
- **No hook points beyond pre/post-setup.** Enterprise forks want at minimum: `pre-overlay`, `pre-scope-resolve`, `post-scope-resolve`, `pre-nix-build`, `post-install`, `pre-uninstall`.

### 2.2 Design

Stable, minimal, documented hook lifecycle - six phases, three tiers, one contract.

<!-- markdownlint-disable MD029 -->

1. **Hook phases**, invoked in this order:

| Phase                | When                                     | Abort behaviour                |
| -------------------- | ---------------------------------------- | ------------------------------ |
| `pre-setup`          | immediately after argv parse             | non-zero aborts                |
| `pre-overlay`        | before overlay scopes load               | non-zero rejects overlay       |
| `pre-scope-resolve`  | after parse, before `resolve_scope_deps` | non-zero aborts                |
| `post-scope-resolve` | after `sort_scopes`                      | non-zero aborts                |
| `pre-nix-build`      | before `nix profile install`             | non-zero aborts                |
| `post-install`       | after successful install                 | non-zero warns, does not abort |
| `pre-uninstall`      | start of `nix/uninstall.sh`              | non-zero aborts                |

2. **Tier discovery and ordering.** For each phase, the core runs, in order:
   - `$ENV_DIR/hooks/<phase>.d/` (user tier) - user-writable
   - `$NIX_ENV_ORG_OVERLAY_DIR/hooks/<phase>.d/` (org tier) - read-only from user
   - base repo has no hooks by default

   Wait - this is wrong for deployment: org policies should run **first**, not last, so user hooks can't bypass them. Correct order:

   **base → org → user** (lexical within tier). Matches `enterprise_notes.md:98`.

3. **Exposed environment contract.** Documented in `nix/lib/README.md` and `docs/customization.md`:

   ```text
   NIX_ENV_PHASE        # current phase name (read-only)
   NIX_ENV_PLATFORM     # macos|linux|wsl
   NIX_ENV_VERSION      # core version (git describe or tarball VERSION)
   NIX_ENV_MODE         # install|upgrade|repair
   NIX_ENV_DRY_RUN      # 0|1
   NIX_ENV_SCOPES       # space-separated resolved scope list (post-resolve only)
   NIX_ENV_OVERLAY_DIRS # colon-separated list of active overlay dirs
   ```

   This is a **stable API**. Changes require a minor version bump and deprecation path.

4. **Hook helper library.** Ship `$ENV_DIR/hooks/_lib.sh` (copied on first install from `nix/lib/hook_lib.sh`) exposing `hook_log`, `hook_fail`, `hook_require_scope`, `hook_require_platform`. Keeps enterprise hook authors on a narrow, versioned surface.

5. **Hook contract test harness.** `tests/scripts/hook_contract.sh` runs a synthetic install with fixture hooks for each phase; asserts invocation order, env var availability, abort semantics.

<!-- markdownlint-enable MD029 -->

### 2.3 Acceptance criteria

- Six hook phases exist and are invoked at the documented points.
- Tier order is base → org → user, lexical within tier, validated by test harness.
- `docs/customization.md` has a "Hooks" section with the full phase list, env var list, ordering rules, and abort semantics.
- `$ENV_DIR/hooks/README.md` is written on first install, describing the contract for local authors.
- `hook_lib.sh` exists and is versioned; `HOOK_LIB_VERSION` env var is exposed for forward-compat checks.
- Changing the env var contract in a breaking way fails a dedicated contract test.

### 2.4 Tasks

- [ ] Add four new hook phase points in `nix/setup.sh` and `nix/uninstall.sh`.
- [ ] Refactor `phase_platform_run_hooks` to iterate tiers in order and honour abort semantics per phase.
- [ ] Write `nix/lib/hook_lib.sh` with `hook_log`, `hook_fail`, `hook_require_scope`, `hook_require_platform`; set `HOOK_LIB_VERSION`.
- [ ] Write `$ENV_DIR/hooks/README.md` template; install on first run.
- [ ] Expose `NIX_ENV_MODE`, `NIX_ENV_DRY_RUN`, `NIX_ENV_SCOPES`, `NIX_ENV_OVERLAY_DIRS` to hook environment.
- [ ] Write `tests/scripts/hook_contract.sh` + bats wrapper.
- [ ] Document full contract in `docs/customization.md` "Hooks" section.
- [ ] Add contract test to CI (required check).

---

## 3. Telemetry and doctor JSON contract

### 3.1 Re-review

`nx doctor --json` exists (`.assets/lib/nx_doctor.sh`). `install.json` is written. Claims in `docs/enterprise.md` say "Fleet telemetry: Scaffold only." But:

- **JSON schema is not versioned.** No `schema_version` field in `install.json` or `nx doctor --json` output.
- **No documented schema file.** Aggregators have no contract to code against.
- **`nx doctor --json` output shape is ad-hoc** - each `_check` emits a loose `{name,status,detail}` object. No enum for `status`, no categorization (hardware/config/runtime/security).
- **`install.json` fields aren't stable.** If a future refactor renames `source` → `install_source`, fleet dashboards break silently.
- **No push mechanism** - and none should exist in upstream; that's the fork's job. But the **pull contract** (what the fork reads off disk) needs to be stable.

### 3.2 Design

Make the JSON outputs a **stable, versioned, schema-documented public API**.

1. **`schema_version` field** added to both `install.json` and `nx doctor --json`. Bumped on breaking changes. Semver for JSON: MAJOR on rename/remove, MINOR on addition, PATCH on documentation-only change.

2. **Ship JSON schemas**: `schemas/install.schema.json` and `schemas/doctor.schema.json`. Validated in CI with `check-jsonschema` (pre-commit hook already in place; extend to schemas).

3. **Stabilize `nx doctor --json` shape**:

   ```json
   {
     "schema_version": "1.0.0",
     "core_version": "1.0.0",
     "timestamp": "2026-04-24T12:00:00Z",
     "platform": "linux",
     "summary": {"pass": 12, "warn": 1, "fail": 0},
     "checks": [
       {"name": "nix_available", "category": "runtime",
        "status": "pass", "severity": "info", "detail": ""}
     ]
   }
   ```

   Categories: `runtime`, `config`, `security`, `overlay`, `scope`. Status: `pass|warn|fail|skip`. Severity: `info|warning|error|critical`.

4. **Stabilize `install.json` shape**. Document every field. Add `schema_version`, keep `source` + `version` + `date` + `scopes` + `host_id` (hashed, not raw hostname - privacy-preserving) + `core_version` + `platform`. Remove any undocumented fields.

5. **Telemetry opt-in flag** as a **contract seam**, not an implementation:
   - `NIX_ENV_TELEMETRY=on|off` (default `off`).
   - When `on`, core writes `$DEV_ENV_DIR/telemetry/events.ndjson` (append-only, rotated at 1 MB).
   - Each event has `schema_version`, `event`, `timestamp`, `fields`.
   - **Core never pushes anything upstream.** A fork's hook (or cron job) reads the file and forwards.
   - Events emitted: `install.start`, `install.complete`, `install.fail`, `upgrade.complete`, `doctor.run`.

6. **Privacy discipline**. Hostname and username are never written raw to telemetry or install.json - only as `sha256(secret_salt || host/user)` where `secret_salt` is generated on first install and stored in `$DEV_ENV_DIR/salt` (600 perms). Documented in `docs/enterprise.md`.

### 3.3 Acceptance criteria

- `install.json` and `nx doctor --json` both emit `schema_version`.
- `schemas/install.schema.json` and `schemas/doctor.schema.json` exist; CI validates real output against them.
- Hashing of hostname/username is documented and tested.
- `NIX_ENV_TELEMETRY=on` causes `events.ndjson` to be written; `off` (default) writes nothing.
- No network calls made by upstream under any telemetry setting.
- Breaking changes to either schema require a bumped `schema_version` major version and a `CHANGELOG.md` entry.

### 3.4 Tasks

- [ ] Add `schema_version` to `install.json` writer in `.assets/lib/install_record.sh`.
- [ ] Add `schema_version`, `timestamp`, `core_version`, `platform`, `summary`, `category`, `severity` to `nx_doctor.sh` JSON output.
- [ ] Write `schemas/install.schema.json` and `schemas/doctor.schema.json`.
- [ ] Add CI job that runs `nx doctor --json` in a Docker container and validates against schema.
- [ ] Implement `$DEV_ENV_DIR/salt` generation on first install; use for host/user hashing.
- [ ] Add `NIX_ENV_TELEMETRY` gating around event emission points.
- [ ] Implement `events.ndjson` append-only writer with 1 MB rotation.
- [ ] Document all of the above in `docs/enterprise.md` under a new "Telemetry contract" section.
- [ ] Bats tests: schema conformance, hashing consistency, rotation, opt-in gating.

---

## 4. Policy enforcement seam

### 4.1 Re-review

`enterprise_notes.md:33` lists `policy.yaml` (ban/require scopes) as fork work. But the core has **no entry point** where a policy file would be consulted today. Adding one later without breaking callers requires the seam to exist first.

### 4.2 Design

Add a single, minimal policy-consultation seam in scope resolution. No policy file format is defined; the seam simply **invokes a hook that can veto scope sets**.

1. **New hook phase `scope-policy`**, invoked between `resolve_scope_deps` and `sort_scopes`. Exposed env:
   - `NIX_ENV_REQUESTED_SCOPES` - what the user asked for (pre-resolve)
   - `NIX_ENV_RESOLVED_SCOPES` - post-resolve list
   - `NIX_ENV_POLICY_FILE` - path if `$NIX_ENV_ORG_OVERLAY_DIR/policy.yaml` exists

2. **Hook exit codes**:
   - `0` - allow
   - `1` - deny (abort install with the hook's stderr as the user-facing reason)
   - `2` - modify (hook writes adjusted scope list to `$NIX_ENV_POLICY_RESULT_FILE`; core reloads)

3. **No YAML parser in core.** The fork implements whatever DSL it wants; the core just invokes the hook. This keeps the seam zero-dependency.

4. **Dry-run mode**: `nx policy check` - runs the scope-policy hook in isolation, prints its decision, does nothing else. Lets ops validate policies against user profiles without installs.

### 4.3 Acceptance criteria

- `scope-policy` hook phase exists and runs at the documented point.
- Exit code 1 aborts install with the hook's stderr surfaced to the user cleanly.
- Exit code 2 triggers a re-read of scopes from the result file.
- `nx policy check --scopes foo,bar` runs the hook dry.
- Documented in `docs/customization.md`.
- Bats fixture hooks cover all three exit-code paths.

### 4.4 Tasks

- [ ] Add `scope-policy` phase point in `nix/lib/phases/scopes.sh`.
- [ ] Implement exit-code semantics (including scope rewrite via `NIX_ENV_POLICY_RESULT_FILE`).
- [ ] Implement `nx policy check` subcommand.
- [ ] Write three fixture hooks and bats test coverage.
- [ ] Document the seam in `docs/customization.md`.

---

## 5. Reserved env var contract

### 5.1 Re-review

`enterprise_notes.md:58-70` lists seven reserved env vars. None are validated or warned on in upstream. A fork depending on `NIX_ENV_OVERLAY_URL` has no guarantee the core won't later collide with that name.

### 5.2 Design

1. **Single registry file**: `nix/lib/reserved_env.sh` lists all `NIX_ENV_*` vars with: name, purpose, owner (core|overlay|fork), expected type, default.

2. **Collision detection**: pre-commit hook that greps for `NIX_ENV_*` usages across the repo and asserts every reference is in the registry. New vars require a registry entry.

3. **Runtime warning**: on startup, `phase_bootstrap` iterates `env | grep '^NIX_ENV_'` and emits a single-line warning per variable that is set but not in the registry (unless `NIX_ENV_SUPPRESS_UNKNOWN_WARN=1`). Forks add their vars to an `extra_registry` file without forking core.

4. **`nx env` subcommand**: prints the registry + any unknown set vars + the current values. Operationally useful and self-documenting.

### 5.3 Acceptance criteria

- `nix/lib/reserved_env.sh` exists and is the single source of truth.
- CI fails if a new `NIX_ENV_*` reference is added without a registry entry.
- Unknown `NIX_ENV_*` vars at runtime emit exactly one warning line each.
- `nx env` prints the registry and current values.
- A fork can extend via `$NIX_ENV_ORG_OVERLAY_DIR/reserved_env.sh` without modifying core.

### 5.4 Tasks

- [ ] Write `nix/lib/reserved_env.sh` with all current + reserved vars.
- [ ] Implement pre-commit collision hook.
- [ ] Add runtime warning in `phase_bootstrap`.
- [ ] Implement `nx env` subcommand.
- [ ] Support overlay registry extension (`$NIX_ENV_ORG_OVERLAY_DIR/reserved_env.sh`).
- [ ] Bats tests: registry enforcement, warning emission, overlay extension.
- [ ] Document in `docs/enterprise.md`.

---

## 6. Provenance and version identity

### 6.1 Re-review

`install.json` records `source` (git|tarball) and `version` (git describe or VERSION file). Phase 1 §3 already hardens the producer side (releases with tarballs, SBOMs, cosign bundles). Phase 2's job is to make that provenance **queryable and verifiable from the installed machine** so a fleet tool can build trust without round-trips.

Gaps today:

- **No verification command.** A sysadmin with `install.json` has no one-line command to confirm the installed version matches an upstream signed release.
- **No build fingerprint.** `install.json.core_version` is a string; there's no way to distinguish "from my clone with uncommitted changes" vs "from a signed release tarball".
- **Rollback story is implicit.** `nix profile` history exists, but `install.json` doesn't link to it.

### 6.2 Design

1. **Extend `install.json`** with `source_fingerprint`:

   ```json
   {
     "source": "tarball",
     "source_fingerprint": {
       "tarball_sha256": "abc123...",
       "cosign_bundle": "/path/to/bundle",
       "verified_at": "2026-04-24T12:00:00Z"
     }
   }
   ```

   For `source: "git"`, fingerprint is `{"commit": "...", "dirty": true|false}`.

2. **`nx verify` subcommand**:
   - For tarball installs, re-verifies the cosign bundle against the stored tarball hash.
   - For git installs, compares HEAD against the recorded commit.
   - Exit 0 on success, non-zero + clear message on mismatch.
   - Offline-safe: tarball verification needs the bundle on disk (stored on first install); cosign verification uses Rekor log cached at install time.

3. **Link `install.json` to nix profile generation number**: `nix_profile_generation` field. Enables a fork's "rollback to last-verified generation" automation with one file read.

4. **`--verify-on-install`** flag forces upstream release verification at install time (requires network; downloads and checks cosign bundle). Off by default to preserve offline install; when on, failure aborts install.

### 6.3 Acceptance criteria

- `install.json` contains `source_fingerprint` for both git and tarball installs.
- `nx verify` works offline for tarball installs (using cached bundle).
- `nx verify` detects a dirty git worktree and reports it.
- `nix_profile_generation` is recorded and updated on every successful install.
- `--verify-on-install` gate is present and tested.
- Documented under a "Provenance" section in `docs/enterprise.md`.

### 6.4 Tasks

- [ ] Extend `install_record.sh` to compute + record `source_fingerprint`.
- [ ] Add `nix_profile_generation` recording after every install.
- [ ] Write `nx verify` subcommand; cover tarball + git paths.
- [ ] Add `--verify-on-install` flag to `nix/setup.sh`; implement network verify with cosign.
- [ ] Cache cosign bundle under `$DEV_ENV_DIR/provenance/` on tarball install.
- [ ] Bats tests: clean git, dirty git, tarball verify success, tarball verify tampered.
- [ ] Document provenance contract in `docs/enterprise.md`.

---

## 7. Catalog surface (IDP-agnostic)

### 7.1 Re-review

`enterprise_notes.md:38-56` describes IDP consumption (Backstage, Port, etc.) as fork work. Agreed - upstream must not ship Backstage `catalog-info.yaml`. But upstream **can** ship a minimal IDP-agnostic metadata document that any catalog can consume or adapt.

### 7.2 Design

Ship a single `metadata.yaml` at repo root with generic fields:

```yaml
name: envy-nx
kind: tool
owner: unassigned
description: Cross-platform developer environment provisioner.
homepage: https://github.com/szymonos/envy-nx
documentation: https://szymonos.github.io/envy-nx
source: https://github.com/szymonos/envy-nx
version: 1.0.0        # updated by release workflow
license: MIT
platforms: [linux, macos, wsl]
install:
  - type: git
    command: "git clone https://github.com/szymonos/envy-nx && ./envy-nx/nix/setup.sh"
  - type: tarball
    url: https://github.com/szymonos/envy-nx/releases/latest/download/envy-nx.tar.gz
      signature: https://github.com/szymonos/envy-nx/releases/latest/download/envy-nx.tar.gz.bundle
```

**Not Backstage-specific.** Forks write adapters: Backstage `catalog-info.yaml`, Port blueprints, internal catalogs - all derive from `metadata.yaml`. Upstream commits to keeping this file's schema stable.

Schema versioned like the JSON contracts (§3): `schema_version: 1.0.0` at the top, `schemas/metadata.schema.json` ships in-repo.

### 7.3 Acceptance criteria

- `metadata.yaml` exists at repo root with `schema_version`.
- `schemas/metadata.schema.json` validates it in CI.
- `version` field is auto-updated by the release workflow.
- A fork can generate a Backstage `catalog-info.yaml` from `metadata.yaml` with a 20-line script (smoke-test this with a sample adapter in `examples/backstage_adapter.sh`).
- Documented in `docs/enterprise.md` under "Catalog integration".

### 7.4 Tasks

- [ ] Write `metadata.yaml` and `schemas/metadata.schema.json`.
- [ ] Add schema validation to pre-commit.
- [ ] Extend `.github/workflows/release.yml` (Phase 1 §3) to bump `metadata.yaml:version` on tag.
- [ ] Write `examples/backstage_adapter.sh` as a reference adapter (not imported by anything upstream).
- [ ] Document the catalog surface in `docs/enterprise.md`.

---

## 8. Effort and sequencing

| § | Block                            | Est. effort    | Blocks          |
| - | -------------------------------- | -------------- | --------------- |
| 5 | Reserved env var contract        | 1 d            | nothing         |
| 7 | Catalog surface                  | 0.5 d          | nothing         |
| 2 | Hook lifecycle contract          | 2.5 d          | §1, §4          |
| 1 | Overlay distribution contract    | 3 d            | §4              |
| 3 | Telemetry / doctor JSON contract | 2 d            | nothing         |
| 4 | Policy enforcement seam          | 1.5 d          | §2              |
| 6 | Provenance and version identity  | 2 d            | Phase 1 §2 + §3 |
|   | **Total for Phase 2**            | ~12.5 dev-days |                 |

Recommended order: §7 → §5 → §2 → §1 → §4 → §3 → §6. Final tag: `v1.1.0` (minor - purely additive).

### Exit criteria for Phase 2

A third party - with **no** changes to upstream - can:

1. Publish an overlay (scopes + hooks + `overlay.yaml`) that the core loads, verifies via pre-overlay hook, and enforces via policy hook.
2. Consume `install.json` + `nx doctor --json` + `metadata.yaml` with published JSON schemas and stable field semantics.
3. Verify any running install's provenance offline with `nx verify`.
4. Add custom behaviour at six hook points across the install/upgrade/uninstall lifecycle without patching a single upstream file.
5. Reserve their own `NIX_ENV_*` vars via the overlay registry without colliding with core or future core additions.

If any of those five statements require "patch the upstream", Phase 2 is not done.
