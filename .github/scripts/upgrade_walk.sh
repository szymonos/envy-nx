#!/usr/bin/env bash
: '
# Walk every released tag (newest -> oldest) and upgrade each to HEAD
.github/scripts/upgrade_walk.sh

# Walk only specific versions (space-separated)
WALK_VERSIONS="v1.5.5 v1.4.0 v1.3.0" .github/scripts/upgrade_walk.sh

# Upgrade target = a non-HEAD ref (defaults to current HEAD otherwise)
TARGET_REF=feature/foo .github/scripts/upgrade_walk.sh

# Read-only source repo (Docker bind-mount): clone from SRC_REPO into WORK_REPO
SRC_REPO=/src WORK_REPO=$HOME/work .github/scripts/upgrade_walk.sh

# Different scope set for the install + upgrade pair
TARGET_SCOPES="--shell --python --unattended" .github/scripts/upgrade_walk.sh
'
# Cross-version upgrade walk - shared by .github/workflows/test_upgrade_walk.yml
# and the local Docker reproduction (`make test-upgrade-walk`).
#
# Per iteration: wipe user-scope state, install at $tag, switch repo to HEAD,
# run `nx setup --skip-repo-update`, verify family files + version + doctor.
# Fail-fasts at first failure to surface the upgrade-supported floor.
#
# Inputs (env vars):
#   SRC_REPO       optional; if set, clone from this read-only path into WORK_REPO
#   WORK_REPO      writable repo dir (default: $PWD; required if SRC_REPO is set)
#   TARGET_REF     ref to use as upgrade target (default: current HEAD)
#   TARGET_SCOPES  scope flags for install + upgrade (default: --shell --unattended)
#   WALK_VERSIONS  space-separated tags to walk (default: all v*.*.*)
#   WALK_FLOOR     skip tags older than this version (e.g. v1.5.0). Bump as
#                  rollouts retire old installs - shorter walk = faster CI.
set -eo pipefail

export PATH="$HOME/.nix-profile/bin:$PATH"
export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

SRC_REPO="${SRC_REPO:-}"
WORK_REPO="${WORK_REPO:-$PWD}"
TARGET_REF="${TARGET_REF:-}"
TARGET_SCOPES="${TARGET_SCOPES:---shell --unattended}"
WALK_VERSIONS="${WALK_VERSIONS:-}"
WALK_FLOOR="${WALK_FLOOR:-}"

# If SRC_REPO points at a read-only clone source (typical for Docker bind-mount),
# clone it to WORK_REPO so we can checkout tags / branches.
if [ -n "$SRC_REPO" ] && [ "$SRC_REPO" != "$WORK_REPO" ]; then
  printf "\n\e[95;1m===== preparing work clone (%s -> %s) =====\e[0m\n" "$SRC_REPO" "$WORK_REPO"
  git clone "$SRC_REPO" "$WORK_REPO"
fi
cd "$WORK_REPO"

if [ -n "$TARGET_REF" ]; then
  git checkout "$TARGET_REF" 2>&1 | sed 's/^/  [git] /'
fi

target_sha="$(git rev-parse HEAD)"
target_ver="$(awk '/^## \[[0-9]+\.[0-9]+\.[0-9]+\]/{gsub(/[][]/,"",$2); print $2; exit}' CHANGELOG.md)"

if [ -z "$WALK_VERSIONS" ]; then
  WALK_VERSIONS="$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$')"
fi

# Apply the floor (drop tags older than $WALK_FLOOR) if set.
if [ -n "$WALK_FLOOR" ]; then
  WALK_VERSIONS="$(printf '%s\n' $WALK_VERSIONS | awk -v floor="$WALK_FLOOR" '
    function n(v,    p) { sub(/^v/, "", v); split(v, p, "."); return p[1]*1000000 + p[2]*1000 + p[3] }
    n($0) >= n(floor)
  ')"
  printf "\n\e[96mfloor: %s (skipping older tags)\e[0m\n" "$WALK_FLOOR"
fi

fail_count=0
pass_count=0
first_failure=""
summary=""

for v in $WALK_VERSIONS; do
  printf "\n\e[95;1m===== %s -> HEAD (%s / v%s) =====\e[0m\n" "$v" "$target_sha" "$target_ver"

  # 1. Wipe user-scope state from previous iteration (no-op on first run).
  if [ -d "$HOME/.config/nix-env" ]; then
    bash nix/uninstall.sh --env-only 2>&1 | sed 's/^/  [cleanup] /' || true
  fi

  # 2. Install at the OLD version.
  git checkout -B test-from "$v" 2>&1 | sed 's/^/  [git] /'
  if ! bash nix/setup.sh $TARGET_SCOPES 2>&1 | sed 's/^/  [setup-old] /'; then
    printf "\e[31;1mFAIL: install at %s failed\e[0m\n" "$v"
    first_failure="${first_failure:-$v (install)}"
    fail_count=$((fail_count + 1))
    summary="$summary\n  $v: FAIL (install)"
    break
  fi

  # 3. Switch repo to HEAD (simulates user pulling latest).
  git checkout "$target_sha" 2>&1 | sed 's/^/  [git] /'

  # 4. Run upgrade via nx (the user-facing path). --skip-repo-update because
  #    we already did the checkout manually.
  if ! bash "$HOME/.config/nix-env/nx.sh" setup $TARGET_SCOPES --skip-repo-update 2>&1 | sed 's/^/  [setup-new] /'; then
    printf "\e[31;1mFAIL: upgrade from %s failed\e[0m\n" "$v"
    first_failure="${first_failure:-$v (upgrade)}"
    fail_count=$((fail_count + 1))
    summary="$summary\n  $v: FAIL (upgrade)"
    break
  fi

  # 5. Verify the install reflects HEAD's expected state.
  verify_failed=0
  for f in nx.sh nx_pkg.sh nx_scope.sh nx_profile.sh nx_lifecycle.sh nx_doctor.sh profile_block.sh; do
    if [ ! -f "$HOME/.config/nix-env/$f" ]; then
      printf "\e[31m  missing: %s\e[0m\n" "$f"
      verify_failed=1
    fi
  done
  # `nx version` prints "\e[96mdev-env\e[0m <version>" with ANSI color codes;
  # strip them before awk-matching the leading literal.
  installed_ver="$(bash "$HOME/.config/nix-env/nx.sh" version 2>/dev/null |
    sed $'s/\033\\[[0-9;]*m//g' |
    awk '/^dev-env/{print $2; exit}')"
  # Match on MAJOR.MINOR.PATCH only - HEAD-on-non-tag installs encode the
  # commit count + sha (e.g. `v1.6.3-11-g5a2df08`) which is informative but
  # not what we're comparing against the CHANGELOG.
  installed_short="${installed_ver#v}"
  installed_short="${installed_short%%-*}"
  if [ "$installed_short" != "$target_ver" ]; then
    printf "\e[33m  version mismatch: install.json says '%s', expected '%s'\e[0m\n" "$installed_ver" "$target_ver"
    # don't fail on version mismatch alone (could be a tarball install with no .git)
  fi
  if ! bash "$HOME/.config/nix-env/nx.sh" doctor --strict 2>&1 | sed 's/^/  [doctor] /'; then
    printf "\e[33m  doctor --strict reported issues\e[0m\n"
    verify_failed=1
  fi

  if [ "$verify_failed" -ne 0 ]; then
    printf "\e[31;1mFAIL: verification from %s failed\e[0m\n" "$v"
    first_failure="${first_failure:-$v (verify)}"
    fail_count=$((fail_count + 1))
    summary="$summary\n  $v: FAIL (verify)"
    break
  fi

  printf "\e[32;1mPASS: %s -> HEAD\e[0m\n" "$v"
  pass_count=$((pass_count + 1))
  summary="$summary\n  $v: PASS"
done

printf "\n\e[95;1m===== upgrade walk summary =====\e[0m\n"
printf "passed: %d\n" "$pass_count"
printf "failed: %d\n" "$fail_count"
if [ -n "$first_failure" ]; then
  printf "\e[31mfirst failure: %s\e[0m\n" "$first_failure"
fi
printf "%b\n" "$summary"

[ "$fail_count" -eq 0 ]
