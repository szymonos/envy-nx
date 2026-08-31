#!/usr/bin/env bats
# Unit tests for .github/scripts/upgrade_walk.sh version selection - the floor
# filter, the sliding patch window, and the refusals. Drives the real script via
# WALK_DRY_RUN against a synthetic tag set, so these test the shipped selection
# code rather than a copy of it. The walk itself (install + upgrade per tag) needs
# Nix and is covered by .github/workflows/test_upgrade_walk.yml.
# shellcheck disable=SC2154
bats_require_minimum_version 1.5.0

REPO_SRC="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
WALK="$REPO_SRC/.github/scripts/upgrade_walk.sh"

setup() {
  FIXTURE="$(mktemp -d)"
  cd "$FIXTURE" || return 1
  git init -q .
  git config user.email t@example.invalid
  git config user.name t
  printf '## [1.20.0] - 2026-01-01\n' >CHANGELOG.md
  git add CHANGELOG.md
  git commit -qm init
  # Minor lines with deliberately uneven patch counts, so a window boundary that
  # silently kept the wrong end of a line would change the expected output.
  for t in v1.10.0 v1.10.1 v1.10.2 v1.11.0 v1.11.1 v1.12.0 v1.13.0 v1.13.1 v1.13.2 v1.14.0; do
    git tag "$t"
  done
}

teardown() {
  cd /
  rm -rf "$FIXTURE"
}

# stdout only - the floor/window banners are diagnostics on stderr.
_walk() {
  WALK_DRY_RUN=1 bash "$WALK" 2>/dev/null
}

@test "no floor, no window: every tag, newest first" {
  run _walk
  [[ "$status" -eq 0 ]]
  [[ "${lines[0]}" == "v1.14.0" ]]
  [[ "${lines[9]}" == "v1.10.0" ]]
  [[ "${#lines[@]}" -eq 10 ]]
}

@test "floor drops older tags" {
  WALK_FLOOR=v1.12.0 run _walk
  [[ "${#lines[@]}" -eq 5 ]]
  [[ "$output" != *"v1.11"* ]]
  [[ "$output" != *"v1.10"* ]]
}

@test "window 0 is off: every tag survives" {
  WALK_WINDOW=0 run _walk
  [[ "${#lines[@]}" -eq 10 ]]
}

@test "window 1: newest line keeps all patches, older lines collapse to oldest" {
  WALK_WINDOW=1 run _walk
  # v1.14 (1 patch) + oldest of v1.13, v1.12, v1.11, v1.10
  [[ "${#lines[@]}" -eq 5 ]]
  [[ "${lines[0]}" == "v1.14.0" ]]
  [[ "${lines[1]}" == "v1.13.0" ]]
  [[ "${lines[2]}" == "v1.12.0" ]]
  [[ "${lines[3]}" == "v1.11.0" ]]
  [[ "${lines[4]}" == "v1.10.0" ]]
}

@test "window 2: v1.13's three patches all kept, v1.11 and v1.10 collapse" {
  WALK_WINDOW=2 run _walk
  [[ "${#lines[@]}" -eq 7 ]]
  [[ "$output" == *"v1.13.2"* ]]
  [[ "$output" == *"v1.13.1"* ]]
  [[ "$output" == *"v1.13.0"* ]]
  [[ "$output" != *"v1.11.1"* ]]
  [[ "$output" != *"v1.10.1"* ]]
}

@test "window collapses to the OLDEST patch of a line, not the newest" {
  # v1.10 has .0 .1 .2 - the hardest upgrade is .0, and picking .2 would quietly
  # weaken the walk while keeping the tag count identical.
  WALK_WINDOW=1 run _walk
  [[ "$output" == *"v1.10.0"* ]]
  [[ "$output" != *"v1.10.2"* ]]
}

@test "window output stays newest-to-oldest across the boundary" {
  WALK_WINDOW=2 run _walk
  # No `sort -V`: BSD sort has no -V and macOS CI runs the full bats suite, so a
  # GNU-only flag here fails the job rather than the assertion (Copilot PR #76).
  # Compare numerically the way upgrade_walk.sh's own awk does.
  out_of_order="$(printf '%s\n' "${lines[@]}" | awk '
    function n(v,    p) { sub(/^v/, "", v); split(v, p, "."); return p[1]*1000000 + p[2]*1000 + p[3] }
    NR > 1 && n($0) >= prev { print "after " prevline ": " $0 }
    { prev = n($0); prevline = $0 }
  ')"
  [[ -z "$out_of_order" ]]
}

@test "floor and window compose" {
  WALK_FLOOR=v1.11.0 WALK_WINDOW=1 run _walk
  # floor leaves v1.14, v1.13.x, v1.12, v1.11.x; window keeps v1.14 whole then oldest each
  [[ "${#lines[@]}" -eq 4 ]]
  [[ "$output" != *"v1.10"* ]]
  [[ "$output" != *"v1.13.2"* ]]
}

@test "explicit WALK_VERSIONS bypasses floor and window" {
  WALK_VERSIONS="v1.10.1" WALK_FLOOR=v1.13.0 WALK_WINDOW=1 run _walk
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" == "v1.10.1" ]]
}

@test "a floor above every tag refuses instead of passing empty" {
  WALK_FLOOR=v9.9.9 run bash -c "WALK_DRY_RUN=1 bash '$WALK'"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"no versions to walk"* ]]
}

@test "a non-integer WALK_WINDOW is refused, not silently coerced" {
  # awk compares idx <= win as STRINGS when win is non-numeric, which every line
  # satisfies - so a typo'd input walked every tag with nothing in the log to
  # say so (Copilot PR #76).
  WALK_WINDOW=abc run bash -c "WALK_DRY_RUN=1 bash '$WALK'"
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"must be a non-negative integer"* ]]
}

@test "WALK_WINDOW=0 is a valid value, not a rejected one" {
  WALK_WINDOW=0 run _walk
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 10 ]]
}
