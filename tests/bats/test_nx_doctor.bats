#!/usr/bin/env bats
# Unit tests for .assets/lib/nx_doctor.sh
bats_require_minimum_version 1.5.0

DOCTOR_SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/.assets/lib/nx_doctor.sh"

setup() {
  TEST_DIR="$(mktemp -d)"
  export ENV_DIR="$TEST_DIR/nix-env"
  export DEV_ENV_DIR="$TEST_DIR/dev-env"
  export HOME="$TEST_DIR"
  # Skip network in version_skew - 100s of parallel `gh api` calls under
  # xargs -P 4 either rate-limit or hang on /dev/tty auth prompts in a
  # sandbox HOME without gh credentials. Production runs aren't affected.
  export NX_DOCTOR_SKIP_NETWORK=1
  mkdir -p "$ENV_DIR/scopes" "$DEV_ENV_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# -- helpers -----------------------------------------------------------------

_write_install_json() {
  cat >"$DEV_ENV_DIR/install.json" <<'EOF'
{
  "status": "success",
  "phase": "complete",
  "scopes": ["shell", "python"]
}
EOF
}

_write_flake_lock() {
  cat >"$ENV_DIR/flake.lock" <<'EOF'
{
  "nodes": {
    "nixpkgs": {
      "locked": {
        "rev": "abc123"
      }
    }
  }
}
EOF
}

_write_scope_files() {
  cat >"$ENV_DIR/scopes/shell.nix" <<'EOF'
# Shell tools
# bins: fzf bat
{ pkgs }: with pkgs; [ fzf bat ]
EOF
  cat >"$ENV_DIR/scopes/python.nix" <<'EOF'
# Python
# bins: uv
{ pkgs }: with pkgs; [ uv ]
EOF
}

# -- nix_available check ----------------------------------------------------

# Build a fake nix shim that emits a configurable --version string. Returns
# success for everything else, since downstream checks (nix_profile, etc.)
# may also call nix and we don't want them to interfere with the assertion.
_mock_nix_with_version() {
  local _ver="$1"
  mkdir -p "$TEST_DIR/bin"
  cat >"$TEST_DIR/bin/nix" <<EOF
#!/bin/sh
if [ "\$1" = "--version" ]; then
  printf 'nix (Nix) %s\n' '$_ver'
  exit 0
fi
exit 0
EOF
  chmod +x "$TEST_DIR/bin/nix"
}

@test "nix_available fails when nix version is below the 2.18 floor" {
  _write_flake_lock
  _write_install_json
  _mock_nix_with_version "2.4.1"
  PATH="$TEST_DIR/bin:$PATH" run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"FAIL  nix_available"* ]]
  [[ "$output" == *"below the supported floor"* ]]
  [[ "$output" == *"Fix:"* ]]
}

@test "nix_available passes when nix version meets the floor" {
  _write_flake_lock
  _write_install_json
  _mock_nix_with_version "2.18.0"
  PATH="$TEST_DIR/bin:$PATH" run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"PASS  nix_available"* ]]
}

@test "nix_available parses Determinate Nix wrapper format (trailing version wins)" {
  _write_flake_lock
  _write_install_json
  # mimic: "nix (Determinate Nix 3.6.5) 2.34.1" - the trailing 2.34.1 is the floor we care about
  mkdir -p "$TEST_DIR/bin"
  cat >"$TEST_DIR/bin/nix" <<'EOF'
#!/bin/sh
if [ "$1" = "--version" ]; then
  printf 'nix (Determinate Nix 3.6.5) 2.34.1\n'
  exit 0
fi
exit 0
EOF
  chmod +x "$TEST_DIR/bin/nix"
  PATH="$TEST_DIR/bin:$PATH" run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"PASS  nix_available"* ]]
}

# -- flake_lock check --------------------------------------------------------

@test "flake_lock passes when flake.lock exists with nixpkgs node" {
  _write_flake_lock
  _write_install_json
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"PASS  flake_lock"* ]]
}

@test "flake_lock fails when flake.lock is missing" {
  _write_install_json
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"FAIL  flake_lock"* ]]
}

# -- install_record check ---------------------------------------------------

@test "install_record passes with valid install.json" {
  _write_flake_lock
  _write_install_json
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"PASS  install_record"* ]]
}

@test "install_record warns when install.json is missing" {
  _write_flake_lock
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"WARN  install_record"* ]]
}

@test "install_record warns on failed status" {
  _write_flake_lock
  cat >"$DEV_ENV_DIR/install.json" <<'EOF'
{
  "status": "failed",
  "phase": "nix-profile",
  "scopes": []
}
EOF
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"WARN  install_record"* ]]
  [[ "$output" == *"failed"* ]]
}

# -- scope_binaries check ---------------------------------------------------

@test "scope_binaries warns on missing binary" {
  _write_flake_lock
  _write_install_json
  # use a fake binary name that definitely won't be in PATH
  cat >"$ENV_DIR/scopes/shell.nix" <<'EOF'
# bins: _nx_doctor_test_nonexistent_bin_
{ pkgs }: with pkgs; [ fzf ]
EOF
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"WARN  scope_binaries"* ]]
  [[ "$output" == *"_nx_doctor_test_nonexistent_bin_"* ]]
}

# -- scope_bins_in_profile check --------------------------------------------

# Set up a fake ~/.nix-profile/bin with the given binaries present (created
# as empty executable files). Skips creation when the array is empty.
_write_nix_profile_bins() {
  mkdir -p "$HOME/.nix-profile/bin"
  local _bin
  for _bin in "$@"; do
    : >"$HOME/.nix-profile/bin/$_bin"
    chmod +x "$HOME/.nix-profile/bin/$_bin"
  done
}

@test "scope_bins_in_profile passes when all scope bins are under ~/.nix-profile/bin" {
  _write_flake_lock
  _write_install_json
  _write_scope_files
  _write_nix_profile_bins fzf bat uv
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"PASS  scope_bins_in_profile"* ]]
}

@test "scope_bins_in_profile fails when a scope bin is on PATH but not in nix-profile" {
  _write_flake_lock
  _write_install_json
  _write_scope_files
  # only fzf + uv land in nix-profile; bat is "missing" from the nix-managed set
  _write_nix_profile_bins fzf uv
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"FAIL  scope_bins_in_profile"* ]]
  [[ "$output" == *"shell/bat"* ]]
  [[ "$output" == *"Fix:"* ]]
}

@test "scope_bins_in_profile is skipped when ~/.nix-profile is absent" {
  _write_flake_lock
  _write_install_json
  _write_scope_files
  # do NOT call _write_nix_profile_bins - no ~/.nix-profile/bin/ exists
  run bash "$DOCTOR_SCRIPT"
  # check should be silent (skip), so neither PASS nor FAIL line appears
  [[ "$output" != *"scope_bins_in_profile"* ]]
}

@test "scope_binaries + scope_bins_in_profile skip scopes with (external-installer) sentinel" {
  # Regression: scopes installed by an external installer (e.g. conda via
  # miniforge) live outside ~/.nix-profile/bin/ and are not on PATH in
  # non-interactive shells. The `# bins: (external-installer)` sentinel
  # opts them out of both binary audits.
  _write_flake_lock
  cat >"$DEV_ENV_DIR/install.json" <<'EOF'
{
  "status": "success",
  "phase": "complete",
  "scopes": ["shell", "conda"]
}
EOF
  cat >"$ENV_DIR/scopes/shell.nix" <<'EOF'
# Shell tools
# bins: fzf
{ pkgs }: with pkgs; [ fzf ]
EOF
  cat >"$ENV_DIR/scopes/conda.nix" <<'EOF'
# Miniforge conda - external installer
# bins: (external-installer)
{ pkgs }: [ ]
EOF
  _write_nix_profile_bins fzf
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"PASS  scope_binaries"* ]]
  [[ "$output" == *"PASS  scope_bins_in_profile"* ]]
  # Confirm conda is NOT mentioned as missing in either check.
  [[ "$output" != *"conda/conda"* ]]
  [[ "$output" != *"conda/(external-installer)"* ]]
}

# -- shell_profile check ----------------------------------------------------

@test "shell_profile passes with exactly one managed block" {
  _write_flake_lock
  _write_install_json
  cat >"$HOME/.bashrc" <<'EOF'
# >>> nix-env managed >>>
some content
# <<< nix-env managed <<<
EOF
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"PASS  shell_profile"* ]]
}

@test "shell_profile fails with duplicate managed blocks" {
  _write_flake_lock
  _write_install_json
  cat >"$HOME/.bashrc" <<'EOF'
# >>> nix-env managed >>>
block 1
# <<< nix-env managed <<<
# >>> nix-env managed >>>
block 2
# <<< nix-env managed <<<
EOF
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"FAIL  shell_profile"* ]]
  [[ "$output" == *"duplicate"* ]]
}

@test "shell_profile audits only .bashrc by default (bash invocation)" {
  _write_flake_lock
  _write_install_json
  cat >"$HOME/.bashrc" <<'EOF'
# >>> nix-env managed >>>
some content
# <<< nix-env managed <<<
EOF
  # broken .zshrc must NOT cause a failure when invoked from bash
  cat >"$HOME/.zshrc" <<'EOF'
# legacy zshrc, no managed block
EOF
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"PASS  shell_profile"* ]]
}

@test "shell_profile audits .zshrc when NX_INVOKING_SHELL=zsh" {
  _write_flake_lock
  _write_install_json
  # broken .bashrc must NOT cause a failure when invoked from zsh
  cat >"$HOME/.bashrc" <<'EOF'
# legacy bashrc, no managed block
EOF
  cat >"$HOME/.zshrc" <<'EOF'
# >>> nix-env managed >>>
some content
# <<< nix-env managed <<<
EOF
  NX_INVOKING_SHELL=zsh run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"PASS  shell_profile"* ]]
}

@test "shell_profile fails when invoking shell's rc lacks managed block" {
  _write_flake_lock
  _write_install_json
  # valid .bashrc, broken .zshrc - and we're auditing zsh
  cat >"$HOME/.bashrc" <<'EOF'
# >>> nix-env managed >>>
some content
# <<< nix-env managed <<<
EOF
  cat >"$HOME/.zshrc" <<'EOF'
# legacy zshrc, no managed block
EOF
  NX_INVOKING_SHELL=zsh run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"FAIL  shell_profile"* ]]
  [[ "$output" == *"no managed block in .zshrc"* ]]
}

@test "shell_profile falls back to \$SHELL when NX_INVOKING_SHELL is unset" {
  _write_flake_lock
  _write_install_json
  # broken .bashrc, valid .zshrc; \$SHELL=zsh -> doctor must pick .zshrc
  cat >"$HOME/.bashrc" <<'EOF'
# legacy bashrc, no managed block
EOF
  cat >"$HOME/.zshrc" <<'EOF'
# >>> nix-env managed >>>
some content
# <<< nix-env managed <<<
EOF
  unset NX_INVOKING_SHELL
  SHELL=/usr/bin/zsh run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"PASS  shell_profile"* ]]
}

# -- env_dir_files check ----------------------------------------------------

_write_env_dir_files() {
  : >"$ENV_DIR/flake.nix"
  : >"$ENV_DIR/nx.sh"
  : >"$ENV_DIR/nx_pkg.sh"
  : >"$ENV_DIR/nx_scope.sh"
  : >"$ENV_DIR/nx_profile.sh"
  : >"$ENV_DIR/nx_lifecycle.sh"
  : >"$ENV_DIR/nx_doctor.sh"
  : >"$ENV_DIR/profile_block.sh"
  : >"$ENV_DIR/config.nix"
}

@test "env_dir_files passes when all durable files are present" {
  _write_flake_lock
  _write_install_json
  _write_env_dir_files
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"PASS  env_dir_files"* ]]
}

@test "env_dir_files fails when nx.sh is missing" {
  _write_flake_lock
  _write_install_json
  _write_env_dir_files
  rm "$ENV_DIR/nx.sh"
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"FAIL  env_dir_files"* ]]
  [[ "$output" == *"nx.sh"* ]]
}

# -- shell_config_files check ----------------------------------------------

@test "shell_config_files passes when no shell config is referenced" {
  _write_flake_lock
  _write_install_json
  cat >"$HOME/.bashrc" <<'EOF'
# >>> nix-env managed >>>
echo hello
# <<< nix-env managed <<<
EOF
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"PASS  shell_config_files"* ]]
}

@test "shell_config_files passes when referenced files exist" {
  _write_flake_lock
  _write_install_json
  mkdir -p "$HOME/.config/shell"
  : >"$HOME/.config/shell/aliases_nix.sh"
  cat >"$HOME/.bashrc" <<'EOF'
# >>> nix-env managed >>>
. "$HOME/.config/shell/aliases_nix.sh"
# <<< nix-env managed <<<
EOF
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"PASS  shell_config_files"* ]]
}

@test "shell_config_files fails when a referenced file is missing" {
  _write_flake_lock
  _write_install_json
  mkdir -p "$HOME/.config/shell"
  : >"$HOME/.config/shell/aliases_nix.sh"
  # aliases_git.sh is referenced but doesn't exist
  cat >"$HOME/.bashrc" <<'EOF'
# >>> nix-env managed >>>
. "$HOME/.config/shell/aliases_nix.sh"
[ -f "$HOME/.config/shell/aliases_git.sh" ] && . "$HOME/.config/shell/aliases_git.sh"
# <<< nix-env managed <<<
EOF
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"FAIL  shell_config_files"* ]]
  [[ "$output" == *"aliases_git.sh"* ]]
}

# -- nix_profile_link check ------------------------------------------------

@test "nix_profile_link passes when symlink resolves" {
  _write_flake_lock
  _write_install_json
  mkdir -p "$HOME/nix-target"
  ln -s "$HOME/nix-target" "$HOME/.nix-profile"
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"PASS  nix_profile_link"* ]]
}

@test "nix_profile_link fails when symlink is dangling" {
  _write_flake_lock
  _write_install_json
  ln -s "$HOME/does-not-exist" "$HOME/.nix-profile"
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"FAIL  nix_profile_link"* ]]
  [[ "$output" == *"dangling"* ]]
}

@test "nix_profile_link fails when symlink is missing" {
  _write_flake_lock
  _write_install_json
  # ensure no .nix-profile in test HOME
  [ ! -e "$HOME/.nix-profile" ]
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"FAIL  nix_profile_link"* ]]
  [[ "$output" == *"not found"* ]]
}

# -- cert_bundle check ------------------------------------------------------

@test "cert_bundle passes when no custom certs exist" {
  _write_flake_lock
  _write_install_json
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"PASS  cert_bundle"* ]]
}

@test "cert_bundle fails when custom certs exist but bundle is missing" {
  _write_flake_lock
  _write_install_json
  mkdir -p "$HOME/.config/certs"
  touch "$HOME/.config/certs/ca-custom.crt"
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"FAIL  cert_bundle"* ]]
  [[ "$output" == *"ca-bundle.crt missing"* ]]
}

@test "cert_bundle remediation covers both bundle and vscode-server when both fail" {
  # Regression: when both ca-bundle.crt is missing AND server-env-setup is
  # missing/lacks NODE_EXTRA_CA_CERTS, the Fix line must list both
  # remediations. The earlier `${_fix:-...}` pattern silently dropped the
  # nix/setup.sh hint whenever the bundle hint was set first.
  _write_flake_lock
  _write_install_json
  mkdir -p "$HOME/.config/certs"
  touch "$HOME/.config/certs/ca-custom.crt"
  # No ~/.vscode-server/server-env-setup -> the second branch fires too.
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"FAIL  cert_bundle"* ]]
  [[ "$output" == *"ca-bundle.crt missing"* ]]
  [[ "$output" == *"NODE_EXTRA_CA_CERTS not in server-env-setup"* ]]
  [[ "$output" == *"build_ca_bundle"* ]]
  [[ "$output" == *"re-run nix/setup.sh"* ]]
}

# -- JSON output -------------------------------------------------------------

@test "--json produces valid JSON with status, pass, checks fields and reports failure count" {
  # Combined: structural validity + failure-count semantics. Originally two
  # tests, but they invoke the same `bash $DOCTOR_SCRIPT --json` and just run
  # different jq queries on the output - merging them halves the subprocess
  # cost without losing coverage.
  _write_install_json
  # no flake.lock -> flake_lock FAIL guarantees fail_count > 0 and status="broken"
  run bash "$DOCTOR_SCRIPT" --json
  echo "$output" | jq -e '.status' >/dev/null
  echo "$output" | jq -e '.pass' >/dev/null
  echo "$output" | jq -e '.checks' >/dev/null
  local fail_count
  fail_count="$(echo "$output" | jq -r '.fail')"
  [ "$fail_count" -gt 0 ]
  [[ "$(echo "$output" | jq -r '.status')" == "broken" ]]
}

# -- exit code ---------------------------------------------------------------

@test "exits 1 when any check fails" {
  # no flake.lock -> flake_lock FAIL
  _write_install_json
  run bash "$DOCTOR_SCRIPT"
  [ "$status" -eq 1 ]
}

# -- Fix: hints --------------------------------------------------------------

@test "Fix: hint rendered under failing shell_profile check" {
  _write_flake_lock
  _write_install_json
  cat >"$HOME/.bashrc" <<'EOF'
# legacy bashrc, no managed block
EOF
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"FAIL  shell_profile"* ]]
  [[ "$output" == *"Fix: run nx profile regenerate"* ]]
}

@test "Fix: hint rendered under warning install_record check" {
  _write_flake_lock
  # no install.json -> install_record warns with a Fix
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"WARN  install_record"* ]]
  [[ "$output" == *"Fix: re-run nix/setup.sh to record install provenance"* ]]
}

@test "no Fix: line for passing checks" {
  _write_flake_lock
  _write_install_json
  _write_env_dir_files
  cat >"$HOME/.bashrc" <<'EOF'
# >>> nix-env managed >>>
some content
# <<< nix-env managed <<<
EOF
  run bash "$DOCTOR_SCRIPT"
  # flake_lock passes -> must not have a Fix line for it
  ! grep -q 'PASS.*flake_lock.*Fix:' <<<"$output"
}

# -- doctor.log file ---------------------------------------------------------

@test "writes plain-text doctor.log to DEV_ENV_DIR by default" {
  _write_flake_lock
  _write_install_json
  run bash "$DOCTOR_SCRIPT"
  [ -f "$DEV_ENV_DIR/doctor.log" ]
  # header present
  grep -q '^nx doctor diagnostics$' "$DEV_ENV_DIR/doctor.log"
  grep -q '^date:' "$DEV_ENV_DIR/doctor.log"
  grep -q '^env_dir:' "$DEV_ENV_DIR/doctor.log"
  # per-check lines present
  grep -q 'PASS  flake_lock' "$DEV_ENV_DIR/doctor.log"
  # no ANSI escape codes in the log
  ! grep -q $'\x1b\\[' "$DEV_ENV_DIR/doctor.log"
}

@test "log file includes Fix: lines when checks fail" {
  _write_install_json
  # missing flake.lock -> failure with remediation
  run bash "$DOCTOR_SCRIPT"
  [ -f "$DEV_ENV_DIR/doctor.log" ]
  grep -q 'FAIL  flake_lock' "$DEV_ENV_DIR/doctor.log"
  grep -q 'Fix: re-run nix/setup.sh to generate' "$DEV_ENV_DIR/doctor.log"
}

@test "Full log: path printed only when there are failures or warnings" {
  _write_install_json
  # missing flake.lock -> failure
  run bash "$DOCTOR_SCRIPT"
  [[ "$output" == *"Full log:"* ]]
  [[ "$output" == *"$DEV_ENV_DIR/doctor.log"* ]]
}

@test "--json does not write doctor.log and does not print Full log:" {
  _write_install_json
  run bash "$DOCTOR_SCRIPT" --json
  [ ! -f "$DEV_ENV_DIR/doctor.log" ]
  [[ "$output" != *"Full log:"* ]]
}

# -- JSON remediation field --------------------------------------------------

@test "--json includes remediation field on failing checks" {
  _write_install_json
  # missing flake.lock -> fail with remediation
  run bash "$DOCTOR_SCRIPT" --json
  local rem
  rem="$(echo "$output" | jq -r '.checks[] | select(.name=="flake_lock") | .remediation')"
  [ -n "$rem" ]
  [[ "$rem" == *"re-run nix/setup.sh"* ]]
}

@test "--json remediation field is empty string for passing checks" {
  _write_flake_lock
  _write_install_json
  run bash "$DOCTOR_SCRIPT" --json
  local rem
  rem="$(echo "$output" | jq -r '.checks[] | select(.name=="flake_lock") | .remediation')"
  [ "$rem" = "" ]
}
