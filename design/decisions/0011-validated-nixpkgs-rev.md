# CI-gated rolling nixpkgs revision

The flake tracks `nixpkgs-unstable` and used to resolve it **at each user's
install time**. Nothing stood between an upstream revision and a developer's
machine. The weekly all-scopes build added in v1.19.4 validated a revision *no
user would ever install* - a green Monday build says nothing about what someone
gets on Tuesday, and a first install had no gate at all.

nixpkgs-unstable is Hydra-validated, but against nixpkgs' own test set, not
against this repo's scope combinations. That is why the minikube `bin/kubectl`
collision (decision [0010](0010-lowprio-buildenv-collisions.md)) passed upstream
CI and still broke every `k8s_ext` install.

**Decision:** `nix/nixpkgs_rev.json` holds the revision users install.
`.github/workflows/bump_nixpkgs_rev.yml` advances it weekly, and only after that
revision has built every scope and completed a real `setup.sh` install on
**both** Linux and macOS. Users move to it through the update
channel that already exists - `setup.sh` auto-pulls the repo, `nx self update`
pulls and re-runs setup, and `phase_bootstrap_sync_env_dir` copies the file into
`~/.config/nix-env/` alongside `flake.nix` and `scopes.json`.

The revision ladder, resolved by `_nx_rev_resolve` in `.assets/lib/nx_rev.sh`
and shared by `nx upgrade` and the `nix_profile` phase:

| Precedence | Mode        | Source                      | Set by                 |
| ---------- | ----------- | --------------------------- | ---------------------- |
| 1          | `pinned`    | `$ENV_DIR/pinned_rev`       | `nx pin set`           |
| 2          | `latest`    | nixpkgs-unstable HEAD       | `nx upgrade --latest`  |
| 3          | `validated` | `$ENV_DIR/nixpkgs_rev.json` | the weekly bump        |
| 4          | `none`      | keep the existing lock      | no rev file synced yet |

Mode `none` deliberately does **not** fall through to HEAD: an install too old
to carry the rev file should stay where it is, not silently start tracking HEAD.

**No repo-level `flake.lock`.** A lock file would pin every input and fight
`nx pin`'s `--override-input`. A single scalar layers onto the plumbing that
already exists (`.assets/lib/nx_pkg.sh`), so the constraint in ARCHITECTURE.md §5
still holds - what changed is that the default input is now a validated revision
rather than HEAD.

**No second bookkeeping file for "last known good".** `flake.lock` already *is*
the per-machine record of the revision in use, so `_nx_pkg_upgrade` snapshots it
and restores it when `nix profile upgrade` fails. A separate `last_good_rev`
would be a second source of truth that drifts from profile generations the first
time someone runs `nx gc` (which is `nix profile wipe-history`).

**Consequences:**

- **`nx upgrade` changed meaning** - "latest" became "latest validated". Upgrades
  lag by up to a week by design. `nx upgrade --latest` is the opt-out, and it is
  the only path where the flake.lock restore matters, because it is the only one
  reaching for a revision no CI has built.
- **Never downgrade.** `_nx_rev_is_downgrade` compares the candidate's
  `lastModified` against the locked one, so a user who moved ahead with
  `--latest` is not dragged back whenever the bump is blocked. Going back stays
  possible, but only deliberately, via `nx pin set`.
- **An unverifiable comparison never blocks an upgrade.** `lastModified` is read
  with jq when present and a guarded sed scan otherwise (jq only ships in the
  `base_init` scope, so it is likely but not guaranteed). Unknown on either side
  means proceed.
- **The gate must stay inline in the bump workflow.** A PR created with
  `GITHUB_TOKEN` does not trigger `pull_request` workflows, and `main` has no
  required status checks, so `gh pr merge --auto` would have nothing to wait on.
  The PR is the audit trail and the revert target, not the gate.
- **A silent freeze is now visible.** `nx doctor`'s `nixpkgs_rev` check reports a
  machine that is behind, and surfaces `last_upgrade_error` when a previous
  attempt failed and rolled back.

`test_scope_env.yml` stays, but **lost its weekly schedule to this workflow**.
The two are mirror images: it holds the revision fixed and varies the repo
("does this scope change break the env?", on every relevant PR), while the bump
gate holds the repo fixed and varies the revision ("does this revision break the
env?", weekly). Both variables break the build independently, and the bump
workflow never runs on a PR, so neither subsumes the other. What *did* become
redundant is the schedule: since `build_scope_env.sh` defaults to the pinned
revision, a weekly run would rebuild the same input every Monday.

## Downstream redistributions

This repo is copied into org-internal redistributions (an independent repo synced
by release PR, not a GitHub fork), which inherit the bump workflow with everything
else. Two repo variables keep one file correct in both places:

| Variable                 | Default | Set to `false` when                                                  |
| ------------------------ | ------- | -------------------------------------------------------------------- |
| `NIXPKGS_BUMP_ENABLED`   | on      | the copy should inherit upstream's revision rather than pick its own |
| `NIXPKGS_BUMP_AUTOMERGE` | on      | a ruleset requires a review, so the PR should wait for a human       |

Default to inheriting. A downstream run on the same GitHub-hosted runners
computes a *different* candidate, diverges from the upstream revision, and pays
for the all-scopes build twice for identical signal. It earns its keep only when
the runners sit somewhere upstream's cannot reach - inside a corporate network,
behind a TLS-inspecting proxy - because then the run tests something new.

Two properties of the ruleset on that repo shaped the workflow, and both are
worth knowing before assuming protection makes a bot PR safer:

- It requires **an approving review, not passing status checks**. Delegating the
  gate to the PR's own checks would therefore gate nothing even with protection
  fully enabled - reinforcing why the gate runs inline.
- `require_extra_approval_for_unattributed_changes` charges a second approval for
  any commit whose author is not a real GitHub account. Both bot workflows
  therefore commit as `github-actions[bot]
  <41898282+github-actions[bot]@users.noreply.github.com>` rather than an
  invented `noreply@github.com` identity.

**Scope:** `nix/nixpkgs_rev.json`, `.assets/lib/nx_rev.sh`,
`.assets/lib/nx_pkg.sh`, `nix/lib/phases/nix_profile.sh`,
`.github/workflows/bump_nixpkgs_rev.yml`
