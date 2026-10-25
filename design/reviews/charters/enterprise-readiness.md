# Charter - `enterprise-readiness`

This shard reviews the **enterprise-readiness posture** of the standalone solution. Unlike the other shards (which review code correctness), this one reviews the *boundary* - extension points, machine-readable outputs, the docs that promise enterprise capabilities, and whether the codebase honestly enables the "[For the organization](../../../docs/benefits.md)" vision in `benefits.md` without violating two binding constraints.

## The two binding constraints

These are non-negotiable. Every finding from this shard must respect both:

**(a) Standalone integrity.** The tool must remain complete and useful for an individual developer with no organizational context. No required telemetry endpoints, no required MDM presence, no "phone home" calls. A solo user cloning the repo on a personal Mac must get the full value with zero org-side infrastructure. Any change that compromises this is a regression, regardless of enterprise upside.

**(b) No pollution by unused functionality.** Don't add scaffolding that costs every user but only matters with integration. The overlay system is the canonical *good* example: optional, costs nothing when `NIX_ENV_OVERLAY_DIR` is unset, only kicks in when an org wires it up. *Bad* examples would be a hardcoded telemetry POST, a license-check daemon, a fail-soft "is MDM present?" check that runs on every invocation. If a feature only exists to serve enterprise integration and orgs without it pay nothing, it belongs in the org's overlay or in `enterprise.md` as integration-side documentation.

The framework's value comes from balancing these two constraints against the third goal: **becoming the enterprise standard described in [`benefits.md` → "For the organization"](../../../docs/benefits.md)**. That section claims fleet patch, audit, migrations, vulnerability response, and license visibility as compounding org-scale benefits. The shard's job is to verify those claims still have a plausible delivery path - either via current functionality plus reasonable integration, or via explicit "needs enterprise investment" documentation in `enterprise.md`.

## What good looks like

- **Extension points are documented contracts, not source-only conventions.** Env var names (`NIX_ENV_OVERLAY_DIR`, `NIX_ENV_*`), hook directory names (`pre-setup.d/`, `post-setup.d/`), CLI flags (`--unattended`), JSON schemas (`install.json`, `nx doctor --json`), and exit code conventions are explicitly documented as stable surfaces. Renaming or removing one is a breaking change with CHANGELOG + migration notes.
- **Standalone integrity holds.** Every feature works for a single developer with no org context, no required env vars, no required network endpoints beyond `cache.nixos.org`. The `--unattended` flag is opt-in for MDM/automation; nothing flags-up automatically.
- **The overlay system is the only org-customization seam.** Custom scopes and aliases flow through `NIX_ENV_OVERLAY_DIR`. Hooks are split: per-machine hooks are read from `~/.config/nix-env/hooks/`, and an overlay directory may ship `post-setup.d/` hooks only (decision 0013; subscriptions run none, `design/overlay_catalog.md` 3.7). There is NO parallel "org config" mechanism, no `/etc/nix-env/policy.json`, no implicit org detection. One seam, well documented.
- **`enterprise.md` honestly tracks reality.** The maturity-summary table at the top reflects the current state - `Available` rows are actually working in CI, `Stub` rows correctly identify what the codebase provides vs. what an org must wire up. Citations point to files that still exist.
- **`benefits.md` "For the organization" claims have a delivery path.** Each org-scale benefit (fleet patching, vulnerability response, license visibility, etc.) is either deliverable today via existing functionality + reasonable org integration (and the integration is described in `enterprise.md`), or honestly listed in `enterprise.md` "What needs enterprise investment" with the gap named.
- **Machine-readable outputs are stable schemas.** `install.json` field names, `nx doctor --json` shape, exit codes from `nx` verbs - all documented and version-stable. Schema bumps require explicit CHANGELOG callout.
- **Compliance hygiene.** `nix/uninstall.sh --env-only` removes nix-managed state cleanly, preserving generic config (certs, local PATH); `--dry-run` previews everything; CI verifies removal. Employee offboarding is a clean, auditable operation.
- **Signed artifacts are real and verifiable.** Release tarball, SBOM (`sbom.spdx.json`), and cosign signatures are produced by CI for every tagged release; verification instructions are in `docs/releasing.md` and actually work.
- **Cross-platform parity at the enterprise-feature level.** If `install.json` records provenance on Linux, it does on macOS and WSL too. No platform getting "almost-enterprise" treatment.

## What NOT to flag

These are intentional design choices, NOT gaps. Re-flagging produces noise.

- **Missing fleet telemetry consumer.** Downstream by design - the codebase provides `install.json` and `nx doctor --json` as data sources; the system that ingests, aggregates, and dashboards is enterprise infrastructure. Already documented in `enterprise.md` → "Fleet telemetry".
- **Missing MDM packaging.** Downstream by design - the [Determinate Systems](https://determinate.systems/nix/macos/mdm/) installer is the supported MDM path. Not the codebase's job to ship Jamf scripts.
- **Missing policy enforcement code.** The overlay mechanism IS the answer. Policy rules (allowlists, version gates, required scopes) belong in the org's overlay repository, not the base.
- **`Stub` / `Missing` ratings in the maturity table.** These are honest disclosures, not gaps. Don't flag the rating; flag if the rating itself is no longer accurate.
- **Single-maintainer note.** Acknowledged in `docs/index.md` Limitations and `docs/enterprise.md` risks table.
- **Mocked WSL Pester tests.** Acknowledged limitation; primary review home is the `wsl` shard.
- **Lack of org-shipped overlay.** Overlays are intentionally NOT shipped - every org's overlay is org-specific. The mechanism is what we ship.
- **`curl | sh` for the Nix installer.** See [`docs/decisions.md` → "Why not checksum-pin the Nix installer"](../../../docs/decisions.md#why-not-checksum-pin-the-nix-installer); enterprise answer is pre-installation via the org's approved channel.

## Three output paths for findings

This shard differs from every other shard in the framework because **a finding can flow to one of three destinations**: the codebase, the user-facing enterprise doc, or the upstream enterprise design backlog. Triage routes each finding to the right destination.

1. **Code (and/or correction to existing user docs)** - when a real gap can be closed in the standalone solution without violating (a) or (b), or when an existing claim is wrong. Example: `install.json` field name is unstable across versions → document and version the schema in code AND in `docs/enterprise.md`.

2. **Document org-side responsibility in user-facing docs** - when the finding describes how an org should handle something but the responsibility is theirs, not upstream's. The fix lands in `docs/enterprise.md` (typically "What needs enterprise investment" or "Risks and mitigations"). Example: `benefits.md` claims "vulnerability response becomes a deploy" → describe the org-side flow (security team bumps the pin, sends one message, fleet patches via `nx setup`; `install.json` provenance answers "are we done"). This expands the user-facing assessment without growing upstream code.

3. **Add to upstream's enterprise design backlog** - when the finding proposes a new extension seam upstream should plan and eventually ship. The fix lands in `design/enterprise_design.md` as a new section (or a new task in an existing section), following the doc's existing template (Re-review → Design → Acceptance criteria → Task checklist). Example: "no `nx verify` subcommand to confirm an installed version against an upstream signed release" → add a section proposing the seam with the four-part structure. **The actual implementation of a `design-backlog` finding does NOT happen in this review cycle** - the cycle just records the proposal in the backlog; later PRs pick it up and implement.

Paths 2 and 3 are **the load-bearing mechanism that lets this shard work without violating constraint (b)**. The shard's job is sometimes to *resist* adding code by pushing the responsibility to either user-facing docs or the design backlog. A reviewer that always flags "we need to add X to the codebase right now" is misunderstanding the constraints.

Two routing questions to ask per finding:

- **Path 1 vs paths 2/3** - "does an org without this capability pay any cost?" If yes (any cost on every user), it violates (b) → push to user docs or design backlog. If no (zero cost when unused, like an overlay seam), it can land in code.
- **Path 2 vs path 3** - "is this org-side responsibility (orgs handle it themselves with existing primitives) or upstream-design (we should ship a new seam)?" The first goes to `docs/enterprise.md`; the second goes to `design/enterprise_design.md`.

## References

- [`docs/enterprise.md`](../../../docs/enterprise.md) - user-facing maturity assessment this shard keeps honest; `docs-drift` and `docs-update` findings land here
- [`docs/benefits.md` → "For the organization"](../../../docs/benefits.md) - the vision this shard helps deliver
- [`docs/customization.md`](../../../docs/customization.md) - the overlay model as the canonical pattern
- [`design/enterprise_design.md`](../../enterprise_design.md) - upstream design backlog where `design-backlog` findings land; single source of truth for what upstream needs to build for enterprise readiness
- [`design/enterprise_notes.md`](../../enterprise_notes.md) - reference model for what enterprise forks build downstream (consumed by `enterprise_design.md`)
- [`docs/decisions.md`](../../../docs/decisions.md) - design rationale, especially "Why three package tiers", "Why unfree packages are opt-in", "Why not checksum-pin"
- [`docs/standards.md`](../../../docs/standards.md) - the engineering rigor that backs enterprise claims
