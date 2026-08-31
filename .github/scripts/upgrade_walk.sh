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

# Preview which tags a floor/window pair selects, without installing anything
WALK_DRY_RUN=1 WALK_FLOOR=v1.10.0 WALK_WINDOW=3 .github/scripts/upgrade_walk.sh

# Every patch of every minor line above the floor (window off)
WALK_FLOOR=v1.10.0 WALK_WINDOW=0 .github/scripts/upgrade_walk.sh
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
#   WALK_WINDOW    sliding patch window: walk every patch of the newest N minor
#                  lines, and only the OLDEST patch of each line beyond that.
#                  Empty or 0 walks every tag. Both filters apply only when the
#                  tag list was derived here, never to an explicit WALK_VERSIONS.
#   WALK_DRY_RUN   set to any value to print the resolved tag list and exit 0
#                  without installing anything.
#
# Why the window: walking v1.10.0 AND v1.10.1..v1.10.6 to HEAD retests almost the
# same path seven times - the oldest patch is furthest from HEAD and dominates its
# line. It does not dominate outright, though: a patch release can write on-disk
# state its own line's .0 never wrote (the CQ-001 'nix-env managed' -> 'nix:managed'
# marker rename is exactly that), and upgrading FROM that state is a distinct path.
# So recent lines keep full patch coverage while a regression against them is most
# likely, and older lines collapse to their hardest case. The walk then grows with
# minor releases rather than patch releases, which is what kept pushing it past the
# runner's execution budget.
set -eo pipefail

export PATH="$HOME/.nix-profile/bin:$PATH"
export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

SRC_REPO="${SRC_REPO:-}"
WORK_REPO="${WORK_REPO:-$PWD}"
TARGET_REF="${TARGET_REF:-}"
TARGET_SCOPES="${TARGET_SCOPES:---shell --unattended}"
WALK_VERSIONS="${WALK_VERSIONS:-}"
WALK_FLOOR="${WALK_FLOOR:-}"
WALK_WINDOW="${WALK_WINDOW:-}"

# awk compares idx <= win, and a non-numeric win makes that a STRING comparison
# that every line satisfies - so a typo'd workflow input silently walks every tag
# instead of the window, with nothing in the log to say so. Refuse it up front.
case "$WALK_WINDOW" in
'' | *[!0-9]*)
  if [ -n "$WALK_WINDOW" ]; then
    printf '\e[31;1mWALK_WINDOW must be a non-negative integer, got "%s"\e[0m\n' \
      "$WALK_WINDOW" >&2
    exit 2
  fi
  ;;
esac

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

walk_derived=''
if [ -z "$WALK_VERSIONS" ]; then
  WALK_VERSIONS="$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$')"
  walk_derived=1
fi

# The floor bounds how long the *automatic* walk runs; it must not silently drop a
# tag the caller named. Filtering an explicit WALK_VERSIONS emptied the list and the
# job still exited 0, so "test v1.5.0" reported green having tested nothing.
if [ -n "$WALK_FLOOR" ] && [ -n "$walk_derived" ]; then
  WALK_VERSIONS="$(printf '%s\n' $WALK_VERSIONS | awk -v floor="$WALK_FLOOR" '
    function n(v,    p) { sub(/^v/, "", v); split(v, p, "."); return p[1]*1000000 + p[2]*1000 + p[3] }
    n($0) >= n(floor)
  ')"
  printf "\n\e[96mfloor: %s (skipping older tags)\e[0m\n" "$WALK_FLOOR" >&2
fi

# Sliding patch window. Input is newest-first, so the first time a minor line is
# seen it gets the next line index, and the LAST tag seen in a line is its oldest
# patch. Windowed lines print in place; collapsed lines are held and printed after,
# which keeps the whole list in newest-to-oldest order.
if [ -n "$WALK_WINDOW" ] && [ "$WALK_WINDOW" != "0" ] && [ -n "$walk_derived" ]; then
  WALK_VERSIONS="$(printf '%s\n' $WALK_VERSIONS | awk -v win="$WALK_WINDOW" '
    function line(v,    p) { sub(/^v/, "", v); split(v, p, "."); return p[1] "." p[2] }
    {
      l = line($0)
      if (!(l in idx)) { idx[l] = ++nlines }
      if (idx[l] <= win) { print } else { oldest[idx[l]] = $0 }
    }
    END { for (i = win + 1; i <= nlines; i++) if (i in oldest) print oldest[i] }
  ')"
  printf "\e[96mpatch window: %s (all patches in the newest %s minor lines, oldest patch beyond)\e[0m\n" \
    "$WALK_WINDOW" "$WALK_WINDOW" >&2
fi

# A walk with nothing to walk exits 0 on the fail_count test below, so a bad floor
# or a typo'd tag reads as a pass. Refuse instead.
if [ -z "$(printf '%s' "$WALK_VERSIONS" | tr -d '[:space:]')" ]; then
  printf "\n\e[31;1mno versions to walk (WALK_FLOOR=%s) - refusing to report success\e[0m\n" \
    "${WALK_FLOOR:-unset}" >&2
  exit 1
fi

# Print the resolved walk and stop. Lets a human preview what a floor/window pair
# selects without paying for the walk, and lets the bats tests drive this exact
# selection code rather than a copy of it.
if [ -n "${WALK_DRY_RUN:-}" ]; then
  printf '%s\n' $WALK_VERSIONS
  exit 0
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

  # 2. Install at the OLD version. --skip-repo-update because the walk pins refs
  #    deliberately: without it phase_bootstrap_refresh_repo sees a named branch
  #    (not the detached HEAD that short-circuits it in step 4) and pays a live
  #    `git ls-remote` to GitHub every iteration - measured at 12s vs 6s median,
  #    196s of a 884s walk. The flag has existed since v1.4.0, below any floor.
  git checkout -B test-from "$v" 2>&1 | sed 's/^/  [git] /'
  if ! bash nix/setup.sh $TARGET_SCOPES --skip-repo-update 2>&1 | sed 's/^/  [setup-old] /'; then
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
