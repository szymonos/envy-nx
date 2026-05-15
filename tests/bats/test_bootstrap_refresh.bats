#!/usr/bin/env bats
# Unit tests for phase_bootstrap_refresh_repo + _bootstrap_recover_from_missing_upstream
# (in nix/lib/phases/bootstrap.sh).
#
# Covers two surfaces:
#   1. The unguarded-rev-parse / unguarded-reset bug shape that printed
#      `fatal: ambiguous argument 'origin/<branch>'` to the user's terminal
#      and crashed bootstrap when the local remote-tracking ref was stale
#      (typical: race after a force-push).
#   2. The new "branch deleted from origin" recovery: when the upstream
#      branch is gone (PR merged + auto-deleted), try to switch to the
#      remote's default branch, gated on uncommitted-changes and
#      HEAD-ancestry safety checks.
bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BOOTSTRAP_SH="$REPO_ROOT/nix/lib/phases/bootstrap.sh"

setup() {
  TEST_DIR="$(mktemp -d)"
  REMOTE_BARE="$TEST_DIR/origin.git"
  WORK="$TEST_DIR/work"

  git init -q --bare "$REMOTE_BARE"
  git clone -q "$REMOTE_BARE" "$WORK"
  cd "$WORK" || return # SC2164
  git config user.email t@t
  git config user.name t
  git config init.defaultBranch main
  echo a >a && git add a && git commit -q -m a
  # ensure branch is named 'main' regardless of the system default
  git branch -m main 2>/dev/null || true
  git push -q -u origin main
  # `set-head -a` returns non-zero on some git versions when origin has no
  # symbolic HEAD yet; harmless either way (the recovery falls back to
  # ls-remote probing 'main' / 'master' when symbolic-ref is unset).
  git remote set-head origin -a >/dev/null 2>&1 || true

  # phase_bootstrap_refresh_repo expects these
  export SCRIPT_ROOT="$WORK"

  # source the function and override exec/info/warn so tests don't replace
  # the bats process and we can assert on log output
  warn() { echo "WARN: $*" >&2; }
  info() { echo "INFO: $*"; }
  err() { echo "ERR: $*" >&2; }
  exec() { echo "EXEC-INTERCEPTED: $*"; }
  export -f warn info err exec 2>/dev/null || true

  # shellcheck source=../../nix/lib/phases/bootstrap.sh
  source "$BOOTSTRAP_SH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

_make_branch_then_delete_on_origin() {
  local name="$1"
  git checkout -qb "$name"
  git push -q -u origin "$name"
  git push -q origin --delete "$name"
  git fetch -q --prune origin
}

# ---------------------------------------------------------------------------
# Bug-fix surface: stale local ref must not crash bootstrap or leak `fatal:`
# ---------------------------------------------------------------------------

@test "missing local remote-tracking ref does NOT print 'fatal: ambiguous argument' or crash" {
  # Branch exists on origin; simulate the stale-local-ref state that the
  # v1.10.3 user hit after rapid-fire force-pushes (local origin/<branch>
  # ref pruned or otherwise missing).
  git checkout -qb live-feature
  echo z >z && git add z && git commit -q -m z
  git push -q -u origin live-feature
  rm -f .git/refs/remotes/origin/live-feature .git/packed-refs 2>/dev/null

  unset NX_REEXECED
  run phase_bootstrap_refresh_repo
  [ "$status" -eq 0 ]
  # Critical assertion: no 'fatal:' leak from unguarded git invocations
  [[ ! "$output" =~ "fatal:" ]]
}

@test "missing local remote-tracking ref + branch exists on origin: fetch reconciles the local ref" {
  git checkout -qb live2
  echo z >z && git add z && git commit -q -m z
  git push -q -u origin live2
  rm -f .git/refs/remotes/origin/live2 .git/packed-refs 2>/dev/null

  unset NX_REEXECED
  phase_bootstrap_refresh_repo

  # Post-call, the ref must be back (the fetch path reconciled it)
  run git rev-parse --verify origin/live2
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Recovery: branch deleted from origin
# ---------------------------------------------------------------------------

@test "deleted upstream + clean tree + HEAD on origin/main: switches to main and exec's" {
  # Make a branch that ONLY exists on origin's history line (HEAD = origin/main)
  git checkout -qb tracking-only
  git push -q -u origin tracking-only
  git push -q origin --delete tracking-only
  git fetch -q --prune origin

  unset NX_REEXECED
  run phase_bootstrap_refresh_repo
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no longer exists on origin" ]]
  [[ "$output" =~ "switching to 'main'" ]]
  [[ "$output" =~ "EXEC-INTERCEPTED:" ]]

  # checkout side effects from the function leak through to the test shell
  run git rev-parse --abbrev-ref HEAD
  [ "$output" = "main" ]
}

@test "deleted upstream + HEAD has commits NOT on default: refuses recovery, keeps current branch" {
  git checkout -qb feature
  echo b >b && git add b && git commit -q -m b
  git push -q -u origin feature
  git push -q origin --delete feature
  git fetch -q --prune origin

  unset NX_REEXECED
  run phase_bootstrap_refresh_repo
  [ "$status" -eq 0 ]
  [[ "$output" =~ "HEAD has commits not on origin/main" ]]
  [[ ! "$output" =~ "EXEC-INTERCEPTED:" ]]

  run git rev-parse --abbrev-ref HEAD
  [ "$output" = "feature" ]
}

@test "deleted upstream + uncommitted changes: refuses recovery" {
  _make_branch_then_delete_on_origin dirty-branch
  echo wip >wip-file

  unset NX_REEXECED
  run phase_bootstrap_refresh_repo
  [ "$status" -eq 0 ]
  [[ "$output" =~ "uncommitted changes" ]]
  [[ ! "$output" =~ "EXEC-INTERCEPTED:" ]]

  run git rev-parse --abbrev-ref HEAD
  [ "$output" = "dirty-branch" ]
}

# ---------------------------------------------------------------------------
# No-op cases
# ---------------------------------------------------------------------------

@test "no upstream configured (fresh local branch): silent return, no recovery attempt" {
  git checkout -qb local-only
  # no `--set-upstream` -> branch.<name>.remote / .merge are unset

  unset NX_REEXECED
  run phase_bootstrap_refresh_repo
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "no longer exists on origin" ]]
  [[ ! "$output" =~ "EXEC-INTERCEPTED:" ]]
}

@test "--skip-repo-update bypasses the entire phase" {
  # Even with a deleted upstream, the flag short-circuits at the top
  _make_branch_then_delete_on_origin to-skip

  unset NX_REEXECED
  run phase_bootstrap_refresh_repo --skip-repo-update
  [ "$status" -eq 0 ]
  [[ -z "$output" ]]
}

@test "detached HEAD (CI PR-merge checkout): returns 0 cleanly under set -eo pipefail" {
  # Reproduces the CI failure on the v1.10.4 cut: GitHub Actions checks the
  # PR out at refs/remotes/pull/N/merge in detached HEAD. The reconstruction
  # branch has a chain of `var="$(git config branch.HEAD.*)"` calls, each of
  # which exits 1 with no key found. Under `set -e` (which nix/setup.sh
  # enables), a bare `var="$(failing-cmd)"` propagates the non-zero exit
  # through the assignment and kills the function. Guard with `|| var=""`
  # AND short-circuit on `_head_branch == "HEAD"` (detached - no branch to
  # refresh against either way).
  git checkout -q --detach
  unset NX_REEXECED
  run bash -c '
    set -eo pipefail
    source "'"$BOOTSTRAP_SH"'"
    warn(){ echo "WARN: $*" >&2; }
    info(){ echo "INFO: $*"; }
    err(){ echo "ERR: $*" >&2; }
    SCRIPT_ROOT="'"$WORK"'" phase_bootstrap_refresh_repo
  '
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "EXEC-INTERCEPTED:" ]]
}

@test "NX_REEXECED loop guard: returns 0 immediately, no git work" {
  _make_branch_then_delete_on_origin loop-guard

  export NX_REEXECED=1
  run phase_bootstrap_refresh_repo
  [ "$status" -eq 0 ]
  [[ -z "$output" ]]
}
