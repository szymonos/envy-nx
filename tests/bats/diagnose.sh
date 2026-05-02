#!/usr/bin/env bash
: '
# run from the repo root
bash tests/bats/diagnose.sh
'
# Per-file bats run with 30s timeout and live progress. Identifies which
# file hangs when `make lint-all HOOK=bats-tests` wedges - prek captures
# all hook output until completion, so this script is the way to see which
# specific test file is the culprit.
#
# Output legend:
#   PASS    3.2s  test_foo.bats          file ran fine
#   FAIL(N) 1.1s  test_bar.bats          file failed with exit N
#   HANG   30.0s  test_baz.bats          ← this is the one wedging the hook
#
# Each file gets its own 30s budget; 30s is generous (slowest file is ~15s
# on a healthy machine), so a HANG is unambiguous. Env vars known to make
# tests hang on hostile environments are stripped first.
set -u

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1

# Strip env vars that can cause hangs:
# - HTTP/HTTPS/NO_PROXY (corp proxy unreachable)
# - GH_TOKEN/GITHUB_TOKEN (bad token stalls gh)
# - NIX_ENV_TLS_PROBE_URL (triggers MITM probe code paths)
# - NIX_ENV_OVERLAY_DIR (could point at unreadable corp share)
unset HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY \
  http_proxy https_proxy no_proxy all_proxy \
  GH_TOKEN GITHUB_TOKEN \
  NIX_ENV_TLS_PROBE_URL NIX_ENV_OVERLAY_DIR
# Force git to never prompt (returns non-zero immediately on missing creds).
export GIT_TERMINAL_PROMPT=0
# Block doctor's `gh api` call (network/auth hang risk) - same env var
# tests/bats/test_nx_doctor.bats's setup() exports.
export NX_DOCTOR_SKIP_NETWORK=1

# `timeout` ships with GNU coreutils (Linux/WSL); macOS userland lacks it
# but brewed coreutils installs `gtimeout`. Detect at startup so the helper
# is usable on the same macOS environments the rest of the repo supports.
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT=gtimeout
else
  printf '\e[31mneither `timeout` nor `gtimeout` found.\e[0m install GNU coreutils:\n' >&2
  printf '  macOS: brew install coreutils\n' >&2
  printf '  Linux: should already be present (coreutils package)\n' >&2
  exit 1
fi

printf '%-9s %6s  %s\n' STATUS TIME FILE
printf '%s\n' '--------- ------ -----------------------------------------------'

total_start=$(date +%s)
hung=()
for f in tests/bats/*.bats; do
  name=$(basename "$f")
  printf 'RUN...      ...   %s\n' "$name"
  s=$(date +%s%N)
  "$TIMEOUT" 30 bats "$f" >/dev/null 2>&1
  rc=$?
  e=$(date +%s%N)
  secs=$(awk -v ms="$(((e - s) / 1000000))" 'BEGIN { printf "%.1fs", ms/1000 }')
  case $rc in
  0) status="PASS" ;;
  124)
    status="HANG"
    hung+=("$name")
    ;;
  *) status="FAIL($rc)" ;;
  esac
  # overwrite RUN... line with the final result
  printf '\033[1A\r\033[K%-9s %6s  %s\n' "$status" "$secs" "$name"
done
total_end=$(date +%s)
printf '\nTotal: %ds\n' $((total_end - total_start))

if [ ${#hung[@]} -gt 0 ]; then
  printf '\n\e[31mHung files (>30s):\e[0m\n'
  for h in "${hung[@]}"; do printf '  - %s\n' "$h"; done
  printf '\nTo zoom in on a hung file with per-test timing:\n'
  printf '  bats --timing tests/bats/%s\n' "${hung[0]}"
  exit 1
fi
