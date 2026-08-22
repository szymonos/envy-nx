#!/usr/bin/env bats
# Unit tests for .assets/scripts/linux_setup.sh - the fatal/tolerant split.
#
# Why this file exists: which installer invocations abort the run and which are
# warned past is load-bearing, and both directions fail silently. Make every
# installer fatal and a single auto-detected optional scope (check_distro.sh
# emits `zsh` from nothing more than /usr/bin/zsh existing) aborts the whole
# provision on an unsupported distro. Tolerate one without recording it and
# `nx doctor` reports pass with the tool absent.
#
# Nothing else guards this. shellcheck's SC2015 on the `A && B || warn` chain is
# info-level, below the hook's --severity=warning, so a "clarity" refactor into
# two independent `|| note_optional_failure` guards would silently let distrobox
# be layered on a failed podman install with no test failing.
#
# The script is run for real against a fixture tree; `sudo`, check_distro.sh and
# nix/setup.sh are stubbed so no installer ever executes.
# shellcheck disable=SC2030,SC2031  # subshell var mutations are intentional
bats_require_minimum_version 1.5.0

REPO_SRC="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

setup() {
  # linux_setup.sh is Linux-only: it sources /etc/os-release before the scope
  # loop, so under `set -e` it dies on macOS before reaching any installer and
  # every assertion about tolerated failures becomes meaningless. The macOS CI
  # leg runs the whole tests/bats/*.bats glob, so gate here rather than there.
  [ "$(uname -s)" = 'Linux' ] || skip 'linux_setup.sh is Linux-only'

  FIXTURE="$(mktemp -d)"
  mkdir -p "$FIXTURE"/{bin,home} \
    "$FIXTURE"/.assets/{scripts,lib,check,provision} \
    "$FIXTURE"/nix

  # The real script and the real libraries it sources - copied, not stubbed, so
  # the test tracks whatever linux_setup.sh actually does today.
  cp "$REPO_SRC/.assets/scripts/linux_setup.sh" "$FIXTURE/.assets/scripts/"
  cp "$REPO_SRC/.assets/lib/install_record.sh" "$FIXTURE/.assets/lib/"
  cp "$REPO_SRC/.assets/lib/scopes.sh" "$FIXTURE/.assets/lib/"
  cp "$REPO_SRC/.assets/lib/scopes.json" "$FIXTURE/.assets/lib/"

  SUDO_LOG="$FIXTURE/sudo.log"
  : >"$SUDO_LOG"

  # sudo stub: log the installer basename, then fail if it is in FAIL_LIST.
  # Leading `VAR=value` arguments are consumed the way real sudo does, so an
  # invocation like `sudo FOO=bar script.sh` still logs `script.sh`.
  cat >"$FIXTURE/bin/sudo" <<'STUB'
#!/usr/bin/env bash
while [[ "$1" == *=* && "$1" != /* && "$1" != .* ]]; do shift; done
script="$(basename "$1")"
echo "$script" >>"$SUDO_LOG"
case " ${FAIL_LIST:-} " in
*" $script "*) exit 1 ;;
esac
# check_ssl.sh is a probe, not an installer: it answers on stdout.
if [ "$script" = 'check_ssl.sh' ]; then
  echo "${SSL_PROBE:-true}"
fi
exit 0
STUB

  # check_distro.sh stub: emit exactly the scopes the test asked for.
  cat >"$FIXTURE/.assets/check/check_distro.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' ${DISTRO_SCOPES:-}
STUB

  # Flags the real nix/setup.sh knows about. Harvested from the real
  # parse_args rather than hand-listed, so a scope that gains or loses a flag
  # upstream cannot silently drift out of sync with this fixture.
  grep -oE -- '--[a-z0-9-]+' "$REPO_SRC/nix/lib/phases/bootstrap.sh" |
    sort -u >"$FIXTURE/valid-flags"

  # nix/setup.sh stub: record the args, and reject any flag the real parse_args
  # would reject. Without this the stub swallows anything and the suite cannot
  # see a malformed delegation at all.
  cat >"$FIXTURE/nix/setup.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FIXTURE/nix-setup-args"
touch "$FIXTURE/nix-setup-ran"
_status=0
for _a in "$@"; do
  case $_a in
  --*)
    grep -qxF -- "$_a" "$FIXTURE/valid-flags" || {
      echo "Unknown option: $_a" >&2
      _status=1
    }
    ;;
  esac
done
exit $_status
STUB

  chmod +x "$FIXTURE/bin/sudo" "$FIXTURE/.assets/check/check_distro.sh" \
    "$FIXTURE/nix/setup.sh" "$FIXTURE/.assets/scripts/linux_setup.sh"
}

teardown() {
  rm -rf "$FIXTURE"
}

# Run linux_setup.sh against the fixture. Args are passed straight through.
_run_setup() {
  run env -u scope -u omp_theme \
    HOME="$FIXTURE/home" \
    FIXTURE="$FIXTURE" \
    SUDO_LOG="$SUDO_LOG" \
    FAIL_LIST="${FAIL_LIST:-}" \
    DISTRO_SCOPES="${DISTRO_SCOPES:-}" \
    SSL_PROBE="${SSL_PROBE:-}" \
    PATH="$FIXTURE/bin:$PATH" \
    bash "$FIXTURE/.assets/scripts/linux_setup.sh" "$@"
}

_record_status() {
  jq -r '.status' "$FIXTURE/home/.config/dev-env/install.json"
}

_record_error() {
  jq -r '.error // ""' "$FIXTURE/home/.config/dev-env/install.json"
}

_sudo_ran() {
  grep -qx "$1" "$SUDO_LOG"
}

# --- mandatory installers stay fatal ---------------------------------------

@test "a failing TLS probe aborts before anything is installed" {
  # The whole point of the preflight: on debian/ubuntu apt is plain HTTP, so
  # without it the system upgrade and base packages succeed and the run only
  # dies later at the nix installer, leaving a half-provisioned box.
  SSL_PROBE=false
  _run_setup
  [ "$status" -ne 0 ]
  # `run` overwrites $output, so assert on the script's own output before any
  # further `run` call below replaces it.
  [[ "$output" == *'TLS verification fails'* ]]
  run ! _sudo_ran upgrade_system.sh
  run ! _sudo_ran install_base.sh
  run ! _sudo_ran install_nix.sh
  [ ! -f "$FIXTURE/nix-setup-ran" ]
}

@test "an unknown TLS probe result is not treated as failure" {
  # `unknown` means no curl/wget/python3 yet, not a broken chain -
  # wsl_phases.ps1 only halts on an explicit `false`.
  SSL_PROBE=unknown
  _run_setup
  [ "$status" -eq 0 ]
  run _sudo_ran install_base.sh
}

@test "an auto-detected oh_my_posh scope is not forwarded as a flag" {
  # check_distro.sh emits oh_my_posh whenever an oh-my-posh binary already
  # exists, so this fires on any re-run once a prompt is installed. nix/setup.sh
  # only reaches the scope via --omp-theme and aborts on --oh-my-posh.
  DISTRO_SCOPES="oh_my_posh"
  _run_setup --omp_theme base
  [ "$status" -eq 0 ]
  run ! grep -qxF -- '--oh-my-posh' "$FIXTURE/nix-setup-args"
  run grep -qxF -- '--omp-theme' "$FIXTURE/nix-setup-args"
  [ "$status" -eq 0 ]
}

@test "the hyphenated --omp-theme spelling is accepted" {
  # nix/setup.sh spells this flag --omp-theme; this script's own examples spell
  # it --omp_theme. `declare` rejects a hyphen in a variable name, so without
  # normalisation the hyphenated form aborts the run instead of setting a value.
  _run_setup --omp-theme base
  [ "$status" -eq 0 ]
  run grep -qxF -- 'base' "$FIXTURE/nix-setup-args"
  [ "$status" -eq 0 ]
}

@test "an auto-detected starship scope is not forwarded as a flag" {
  DISTRO_SCOPES="starship"
  _run_setup
  [ "$status" -eq 0 ]
  run ! grep -qxF -- '--starship' "$FIXTURE/nix-setup-args"
}

@test "install_base.sh failure is fatal and stops before nix/setup.sh" {
  FAIL_LIST="install_base.sh"
  _run_setup
  [ "$status" -ne 0 ]
  [ ! -f "$FIXTURE/nix-setup-ran" ]
  run ! _sudo_ran install_nix.sh
  [ "$(_record_status)" = "failed" ]
}

@test "install_nix.sh failure is fatal and stops before nix/setup.sh" {
  FAIL_LIST="install_nix.sh"
  _run_setup
  [ "$status" -ne 0 ]
  [ ! -f "$FIXTURE/nix-setup-ran" ]
  [ "$(_record_status)" = "failed" ]
}

# --- optional scopes are tolerated ------------------------------------------

@test "docker scope failure is tolerated: run continues and records partial" {
  FAIL_LIST="install_docker.sh"
  _run_setup --scope docker
  [ "$status" -eq 0 ]
  _sudo_ran install_docker.sh
  [ -f "$FIXTURE/nix-setup-ran" ]
  [ "$(_record_status)" = "partial" ]
  [[ "$(_record_error)" == *docker* ]]
}

@test "zsh scope failure is tolerated: run continues and records partial" {
  FAIL_LIST="install_zsh.sh"
  _run_setup --scope zsh
  [ "$status" -eq 0 ]
  _sudo_ran install_zsh.sh
  [ -f "$FIXTURE/nix-setup-ran" ]
  [ "$(_record_status)" = "partial" ]
  [[ "$(_record_error)" == *zsh* ]]
}

@test "system upgrade failure is tolerated and does not block base install" {
  FAIL_LIST="upgrade_system.sh"
  _run_setup --sys_upgrade true
  [ "$status" -eq 0 ]
  _sudo_ran upgrade_system.sh
  _sudo_ran install_base.sh
  [ -f "$FIXTURE/nix-setup-ran" ]
  [ "$(_record_status)" = "partial" ]
  [[ "$(_record_error)" == *system-upgrade* ]]
}

# --- the podman -> distrobox dependency --------------------------------------

@test "podman failure prevents distrobox from being layered on it" {
  FAIL_LIST="install_podman.sh"
  _run_setup --scope distrobox
  [ "$status" -eq 0 ]
  _sudo_ran install_podman.sh
  # The whole point: distrobox must NOT be attempted on a missing runtime.
  # `run !` (not a bare `!`) - see SC2314: a bare negation never fails a bats
  # test, so this assertion would silently prove nothing.
  run ! _sudo_ran install_distrobox.sh
  [ "$(_record_status)" = "partial" ]
  [[ "$(_record_error)" == *distrobox* ]]
}

@test "podman succeeding still runs distrobox, and its failure is tolerated" {
  FAIL_LIST="install_distrobox.sh"
  _run_setup --scope distrobox
  [ "$status" -eq 0 ]
  _sudo_ran install_podman.sh
  _sudo_ran install_distrobox.sh
  [ -f "$FIXTURE/nix-setup-ran" ]
  [ "$(_record_status)" = "partial" ]
}

# --- clean run and mixed outcomes -------------------------------------------

@test "a clean run records success, not partial" {
  _run_setup --scope docker
  [ "$status" -eq 0 ]
  _sudo_ran install_docker.sh
  [ -f "$FIXTURE/nix-setup-ran" ]
  [ "$(_record_status)" = "success" ]
}

@test "a fatal failure after a tolerated one keeps the real cause" {
  FAIL_LIST="upgrade_system.sh install_base.sh"
  _run_setup --sys_upgrade true
  [ "$status" -ne 0 ]
  [ "$(_record_status)" = "failed" ]
  # The tolerated failure is context, not the headline - it must not displace
  # the genuine cause of the abort.
  [[ "$(_record_error)" == *"also tolerated: system-upgrade"* ]]
}
