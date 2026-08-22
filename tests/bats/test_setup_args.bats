#!/usr/bin/env bats
# Unit tests for nix/setup.sh argument validation.
#
# Why this file exists: phase_bootstrap_parse_args cannot reject a typo. It
# calls scope_add and reads VALID_SCOPES, both from scopes.sh, which needs jq -
# installed nine steps into setup, after a git pull, a cert sync and a profile
# write. phase_bootstrap_validate_args duplicates the flag list with no
# dependencies so the rejection happens before any of that. Duplication is the
# cost; the set-equality test below is what keeps the two from drifting.
# shellcheck disable=SC2034,SC2154
bats_require_minimum_version 1.5.0

REPO_SRC="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

setup() {
  # shellcheck source=../../nix/lib/io.sh
  source "$REPO_SRC/nix/lib/io.sh"
  # shellcheck source=../../nix/lib/phases/bootstrap.sh
  source "$REPO_SRC/nix/lib/phases/bootstrap.sh"
}

# Flags the parse_args case statement actually accepts. Harvested from the
# source rather than hand-listed - a hand-listed copy would be a third list to
# keep in sync. Case-pattern lines are the only ones indented 4-6 spaces that
# begin with a dash; bodies start with a letter.
_case_flags() {
  awk '/^phase_bootstrap_parse_args\(\) \{/,/^\}$/' "$REPO_SRC/nix/lib/phases/bootstrap.sh" |
    awk '/case "\$1" in/,/^    esac$/' |
    grep -E '^ {4,6}-' |
    grep -oE -- '--?[a-z][a-z0-9-]*' | sort -u
}

# --- the drift guard ---------------------------------------------------------

@test "NX_SETUP_FLAGS matches the flags parse_args accepts" {
  # Both directions matter: a flag added to the case statement but not the
  # array is rejected before it can ever run; a flag in the array but not the
  # case statement passes validation and then dies at "Unknown option".
  local expected actual
  expected="$(_case_flags)"
  actual="$(printf '%s\n' "${NX_SETUP_FLAGS[@]}" | sort -u)"
  [ "$expected" = "$actual" ]
}

@test "the harvest finds the multi-line scope-flag arm, not just its last entry" {
  # Guards the test itself: the scope flags are one backslash-continued case
  # arm, and an extraction keyed on `)` would silently capture only --zsh and
  # make the drift guard above vacuous.
  local flags
  flags="$(_case_flags)"
  [[ "$flags" == *"--az"* ]]
  [[ "$flags" == *"--nodejs"* ]]
  [[ "$flags" == *"-h"* ]]
  [ "$(printf '%s\n' "$flags" | wc -l)" -gt 20 ]
}

# --- validation ---------------------------------------------------------------

@test "every valid flag passes validation" {
  run phase_bootstrap_validate_args "${NX_SETUP_FLAGS[@]}"
  [ "$status" -eq 0 ]
}

@test "flag values are not mistaken for flags" {
  run phase_bootstrap_validate_args --omp-theme base --remove docker az
  [ "$status" -eq 0 ]
}

@test "an unknown flag exits 2" {
  run phase_bootstrap_validate_args --not-a-flag
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option: --not-a-flag"* ]]
}

@test "a dropped leading dash is suggested" {
  # The real report: `nix/setup.sh --shell --pwsh -omp-theme base`.
  run phase_bootstrap_validate_args -omp-theme base
  [ "$status" -eq 2 ]
  [[ "$output" == *"Did you mean --omp-theme?"* ]]
}

@test "the underscore spelling is suggested" {
  # linux_setup.sh takes --omp_theme; nix/setup.sh takes --omp-theme.
  run phase_bootstrap_validate_args --omp_theme base
  [ "$status" -eq 2 ]
  [[ "$output" == *"Did you mean --omp-theme?"* ]]
}

@test "an unknown flag with no near match gets no suggestion" {
  run phase_bootstrap_validate_args --wat
  [ "$status" -eq 2 ]
  [[ "$output" != *"Did you mean"* ]]
}

@test "validation rejects before any phase runs" {
  # The point of the whole change: a typo must not cost a git pull, an
  # ~/.config/nix-env write, or a nix profile install. Asserted end-to-end
  # against the real entry point with a HOME that has no install record.
  local test_home
  test_home="$(mktemp -d)"
  run env HOME="$test_home" bash "$REPO_SRC/nix/setup.sh" -omp-theme base
  [ "$status" -eq 2 ]
  [[ "$output" == *"Did you mean --omp-theme?"* ]]
  # no provenance record, no env dir, no log - nothing was started
  [ ! -e "$test_home/.config/dev-env/install.json" ]
  [ ! -e "$test_home/.config/nix-env" ]
  rm -rf "$test_home"
}
