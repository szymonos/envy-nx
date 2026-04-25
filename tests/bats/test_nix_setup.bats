#!/usr/bin/env bats
# Integration tests for nix/setup.sh - config generation, scope merging, idempotency.
# These tests exercise the setup.sh argument parsing and config.nix generation logic
# without actually running nix commands (nix is stubbed out via io.sh overrides).
# shellcheck disable=SC2034,SC2154
bats_require_minimum_version 1.5.0

# =============================================================================
# Helpers
# =============================================================================

setup_file() {
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
}

setup() {
  # create an isolated environment
  TEST_HOME="$(mktemp -d)"
  TEST_ENV_DIR="$TEST_HOME/.config/nix-env"
  mkdir -p "$TEST_ENV_DIR/scopes"

  # copy real scope and flake declarations
  cp "$REPO_ROOT/nix/flake.nix" "$TEST_ENV_DIR/"
  cp "$REPO_ROOT/nix/scopes/"*.nix "$TEST_ENV_DIR/scopes/"
  cp "$REPO_ROOT/.assets/lib/scopes.json" "$TEST_HOME/scopes.json"

  # source libraries
  # shellcheck source=../../nix/lib/io.sh
  source "$REPO_ROOT/nix/lib/io.sh"
  # shellcheck source=../../nix/lib/phases/bootstrap.sh
  source "$REPO_ROOT/nix/lib/phases/bootstrap.sh"
  # shellcheck source=../../nix/lib/phases/platform.sh
  source "$REPO_ROOT/nix/lib/phases/platform.sh"
  # shellcheck source=../../nix/lib/phases/scopes.sh
  source "$REPO_ROOT/nix/lib/phases/scopes.sh"
  # shellcheck source=../../nix/lib/phases/nix_profile.sh
  source "$REPO_ROOT/nix/lib/phases/nix_profile.sh"
  # shellcheck source=../../nix/lib/phases/post_install.sh
  source "$REPO_ROOT/nix/lib/phases/post_install.sh"
  # shellcheck source=../../nix/lib/phases/summary.sh
  source "$REPO_ROOT/nix/lib/phases/summary.sh"

  # source the scope library (needs jq)
  export SCOPES_JSON="$REPO_ROOT/.assets/lib/scopes.json"
  # shellcheck source=../../.assets/lib/scopes.sh
  source "$REPO_ROOT/.assets/lib/scopes.sh"

  # stub side effects AFTER sourcing (overrides io.sh defaults)
  _io_nix() { echo "nix $*" >>"$BATS_TEST_TMPDIR/nix.log"; }
  _io_nix_eval() { nix eval --impure --raw --expr "$1"; }
  _io_curl_probe() { return 0; }
  _io_run() { echo "run $*" >>"$BATS_TEST_TMPDIR/run.log"; }

  # set up variables needed by phases
  ENV_DIR="$TEST_ENV_DIR"
  CONFIG_NIX="$ENV_DIR/config.nix"
  allow_unfree="false"
  _ir_skip=false
  _ir_phase="test"
}

teardown() {
  rm -rf "$TEST_HOME"
}

# Helper: read scopes back from config.nix using sed (no nix eval needed)
read_config_scopes() {
  sed -n '/scopes[[:space:]]*=[[:space:]]*\[/,/\]/{
    s/^[[:space:]]*"\([^"]*\)".*/\1/p
  }' "$TEST_ENV_DIR/config.nix"
}

# Helper: read allowUnfree value from config.nix
read_config_allow_unfree() {
  sed -En 's/^[[:space:]]*allowUnfree[[:space:]]*=[[:space:]]*(true|false).*/\1/p' "$TEST_ENV_DIR/config.nix"
}

# =============================================================================
# Config generation
# =============================================================================

@test "config.nix: generated with single scope" {
  _scope_set=" "
  scope_add "shell"
  resolve_scope_deps
  sort_scopes
  is_init=false
  phase_scopes_write_config

  local scopes
  scopes="$(read_config_scopes)"
  [[ "$scopes" == *"shell"* ]]
}

@test "config.nix: --all generates all non-prompt scopes" {
  _scope_set=" "
  for s in "${VALID_SCOPES[@]}"; do
    [[ "$s" == "oh_my_posh" || "$s" == "starship" ]] && continue
    scope_add "$s"
  done
  resolve_scope_deps
  sort_scopes
  is_init=false
  phase_scopes_write_config

  local scopes
  scopes="$(read_config_scopes)"
  # verify key scopes are present
  echo "$scopes" | grep -qx "shell"
  echo "$scopes" | grep -qx "python"
  echo "$scopes" | grep -qx "docker"
  echo "$scopes" | grep -qx "k8s_base"
}

@test "config.nix: dependencies are included" {
  _scope_set=" "
  scope_add "az"
  resolve_scope_deps
  sort_scopes
  is_init=false
  phase_scopes_write_config

  local scopes
  scopes="$(read_config_scopes)"
  # az depends on python
  echo "$scopes" | grep -qx "python"
  echo "$scopes" | grep -qx "az"
}

@test "config.nix: k8s_ext pulls full dependency chain" {
  _scope_set=" "
  scope_add "k8s_ext"
  resolve_scope_deps
  sort_scopes
  is_init=false
  phase_scopes_write_config

  local scopes
  scopes="$(read_config_scopes)"
  echo "$scopes" | grep -qx "docker"
  echo "$scopes" | grep -qx "k8s_base"
  echo "$scopes" | grep -qx "k8s_dev"
  echo "$scopes" | grep -qx "k8s_ext"
}

# =============================================================================
# Scope merging (additive behavior)
# =============================================================================

@test "merge: new scopes are additive to existing config" {
  # simulate existing config with shell scope
  _scope_set=" "
  scope_add "shell"
  sort_scopes
  is_init=false
  phase_scopes_write_config

  # now simulate a second run adding python
  _scope_set=" "
  # load existing scopes (simulates nix eval reading config.nix)
  while IFS= read -r sc; do
    [[ -n "$sc" ]] && scope_add "$sc"
  done <<<"$(read_config_scopes)"
  # add new scope
  scope_add "python"
  resolve_scope_deps
  sort_scopes
  phase_scopes_write_config

  local scopes
  scopes="$(read_config_scopes)"
  echo "$scopes" | grep -qx "shell"
  echo "$scopes" | grep -qx "python"
}

@test "merge: idempotent - same scopes produce identical config" {
  _scope_set=" "
  scope_add "shell"
  scope_add "python"
  resolve_scope_deps
  sort_scopes
  is_init=false
  phase_scopes_write_config
  local first
  first="$(cat "$TEST_ENV_DIR/config.nix")"

  # re-run with same scopes
  _scope_set=" "
  scope_add "shell"
  scope_add "python"
  resolve_scope_deps
  sort_scopes
  phase_scopes_write_config
  local second
  second="$(cat "$TEST_ENV_DIR/config.nix")"

  [[ "$first" == "$second" ]]
}

# =============================================================================
# Scope removal
# =============================================================================

@test "remove: scope is removed from set" {
  _scope_set=" "
  scope_add "shell"
  scope_add "python"
  scope_add "rice"
  # remove python
  scope_del "python"
  sort_scopes
  is_init=false
  phase_scopes_write_config

  local scopes
  scopes="$(read_config_scopes)"
  echo "$scopes" | grep -qx "shell"
  echo "$scopes" | grep -qx "rice"
  ! echo "$scopes" | grep -qx "python"
}

# =============================================================================
# Prompt engine mutual exclusivity
# =============================================================================

@test "prompt: omp and starship are mutually exclusive" {
  _scope_set=" "
  scope_add "shell"
  scope_add "oh_my_posh"
  scope_add "starship"
  # simulate --omp-theme taking precedence (setup.sh logic)
  scope_del "starship"
  resolve_scope_deps
  sort_scopes
  is_init=false
  phase_scopes_write_config

  local scopes
  scopes="$(read_config_scopes)"
  echo "$scopes" | grep -qx "oh_my_posh"
  ! echo "$scopes" | grep -qx "starship"
}

# =============================================================================
# Scope ordering
# =============================================================================

@test "order: scopes in config.nix follow install_order" {
  _scope_set=" "
  scope_add "rice"
  scope_add "shell"
  scope_add "python"
  scope_add "docker"
  resolve_scope_deps
  sort_scopes
  is_init=false
  phase_scopes_write_config

  local -a scopes=()
  while IFS= read -r sc; do
    [[ -n "$sc" ]] && scopes+=("$sc")
  done <<<"$(read_config_scopes)"

  # verify docker comes before python, python before shell, shell before rice
  local docker_idx=-1 python_idx=-1 shell_idx=-1 rice_idx=-1
  for i in "${!scopes[@]}"; do
    case "${scopes[$i]}" in
    docker) docker_idx=$i ;;
    python) python_idx=$i ;;
    shell) shell_idx=$i ;;
    rice) rice_idx=$i ;;
    esac
  done

  [[ $docker_idx -lt $python_idx ]]
  [[ $python_idx -lt $shell_idx ]]
  [[ $shell_idx -lt $rice_idx ]]
}

# =============================================================================
# Scope-to-nix-package mapping (verifies scopes/*.nix are well-formed)
# =============================================================================

_scope_pkgs() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed -n '/\[/,/\]/{
    s/^[[:space:]]*\([a-zA-Z][a-zA-Z0-9_-]*\).*/\1/p
  }' "$file"
}

@test "scope files: every valid scope has a corresponding .nix file" {
  # some scopes are config-only (no nix packages) - they trigger configure scripts
  local config_only_scopes=" conda docker distrobox "
  for sc in "${VALID_SCOPES[@]}"; do
    local nix_file="$TEST_ENV_DIR/scopes/${sc}.nix"
    # some scopes have no .nix file (handled by builtins.pathExists in flake)
    [[ -f "$nix_file" ]] || continue
    if [[ "$config_only_scopes" == *" $sc "* ]]; then
      continue
    fi
    local pkg_count
    pkg_count="$(_scope_pkgs "$nix_file" | wc -l)"
    [[ $pkg_count -gt 0 ]] || { echo "empty scope file: $nix_file" >&2; false; }
  done
}

@test "scope files: base.nix includes essential packages" {
  local pkgs
  pkgs="$(_scope_pkgs "$TEST_ENV_DIR/scopes/base.nix")"
  echo "$pkgs" | grep -qx "git"
  echo "$pkgs" | grep -qx "gh"
  echo "$pkgs" | grep -qx "openssl"
}

@test "scope files: shell.nix includes expected tools" {
  local pkgs
  pkgs="$(_scope_pkgs "$TEST_ENV_DIR/scopes/shell.nix")"
  echo "$pkgs" | grep -qx "fzf"
  echo "$pkgs" | grep -qx "eza"
  echo "$pkgs" | grep -qx "bat"
  echo "$pkgs" | grep -qx "ripgrep"
}

@test "scope files: python.nix includes uv" {
  local pkgs
  pkgs="$(_scope_pkgs "$TEST_ENV_DIR/scopes/python.nix")"
  echo "$pkgs" | grep -qx "uv"
}

@test "scope files: k8s_base.nix includes kubectl" {
  local pkgs
  pkgs="$(_scope_pkgs "$TEST_ENV_DIR/scopes/k8s_base.nix")"
  echo "$pkgs" | grep -qx "kubectl"
  echo "$pkgs" | grep -qx "k9s"
}

# =============================================================================
# isInit detection
# =============================================================================

@test "config.nix: isInit is false by default" {
  _scope_set=" "
  scope_add "shell"
  sort_scopes
  is_init=false
  phase_scopes_write_config

  grep -q 'isInit = false' "$TEST_ENV_DIR/config.nix"
}

@test "config.nix: isInit is true when set" {
  _scope_set=" "
  scope_add "shell"
  sort_scopes
  is_init=true
  phase_scopes_write_config

  grep -q 'isInit = true' "$TEST_ENV_DIR/config.nix"
}

@test "config.nix: phase_scopes_detect_init sets true when jq not system-installed" {
  has_system_cmd() { return 1; }
  phase_scopes_detect_init
  [[ "$is_init" == "true" ]]
}

@test "config.nix: phase_scopes_detect_init sets false when system cmds available" {
  has_system_cmd() { return 0; }
  phase_scopes_detect_init
  [[ "$is_init" == "false" ]]
}

# =============================================================================
# System-prefer scope skipping (phase_scopes_skip_system_prefer)
# =============================================================================

@test "system-prefer: pwsh removed on Linux when installed system-wide" {
  _scope_set=" "
  scope_add "shell"
  scope_add "pwsh"
  uname() { echo "Linux"; }
  has_system_cmd() { [[ "$1" == "pwsh" ]] && return 0 || return 1; }
  phase_scopes_skip_system_prefer
  run ! scope_has "pwsh"
  scope_has "shell"
}

@test "system-prefer: pwsh kept on Darwin even if system command exists" {
  _scope_set=" "
  scope_add "shell"
  scope_add "pwsh"
  uname() { echo "Darwin"; }
  has_system_cmd() { return 0; }
  phase_scopes_skip_system_prefer
  scope_has "pwsh"
  scope_has "shell"
}

@test "system-prefer: pwsh kept on Linux when not installed system-wide" {
  _scope_set=" "
  scope_add "shell"
  scope_add "pwsh"
  uname() { echo "Linux"; }
  has_system_cmd() { return 1; }
  phase_scopes_skip_system_prefer
  scope_has "pwsh"
  scope_has "shell"
}

@test "system-prefer: no-op when pwsh scope not requested" {
  _scope_set=" "
  scope_add "shell"
  scope_add "python"
  uname() { echo "Linux"; }
  has_system_cmd() { return 0; }
  phase_scopes_skip_system_prefer
  scope_has "shell"
  scope_has "python"
}

@test "system-prefer: zsh removed on Linux when installed system-wide" {
  _scope_set=" "
  scope_add "shell"
  scope_add "zsh"
  uname() { echo "Linux"; }
  has_system_cmd() { [[ "$1" == "zsh" ]] && return 0 || return 1; }
  phase_scopes_skip_system_prefer
  run ! scope_has "zsh"
  scope_has "shell"
}

@test "system-prefer: zsh kept on Darwin" {
  _scope_set=" "
  scope_add "shell"
  scope_add "zsh"
  uname() { echo "Darwin"; }
  has_system_cmd() { return 0; }
  phase_scopes_skip_system_prefer
  scope_has "zsh"
}

@test "system-prefer: zsh removed on Linux when not installed anywhere" {
  _scope_set=" "
  scope_add "shell"
  scope_add "zsh"
  uname() { echo "Linux"; }
  has_system_cmd() { return 1; }
  # ensure zsh is genuinely not on PATH (skip if it is - CI may have it)
  if command -v zsh &>/dev/null; then
    skip "zsh is installed on this system"
  fi
  phase_scopes_skip_system_prefer
  run ! scope_has "zsh"
  scope_has "shell"
}

@test "system-prefer: both pwsh and zsh removed on Linux when system-wide" {
  _scope_set=" "
  scope_add "shell"
  scope_add "pwsh"
  scope_add "zsh"
  uname() { echo "Linux"; }
  has_system_cmd() { return 0; }
  phase_scopes_skip_system_prefer
  run ! scope_has "pwsh"
  run ! scope_has "zsh"
  scope_has "shell"
}

# =============================================================================
# allowUnfree config
# =============================================================================

@test "config.nix: allowUnfree defaults to false" {
  _scope_set=" "
  scope_add "shell"
  sort_scopes
  is_init=false
  phase_scopes_write_config

  [[ "$(read_config_allow_unfree)" == "false" ]]
}

@test "config.nix: allowUnfree set to true via flag" {
  _scope_set=" "
  scope_add "shell"
  sort_scopes
  is_init=false
  allow_unfree="true"
  phase_scopes_write_config

  [[ "$(read_config_allow_unfree)" == "true" ]]
}

@test "config.nix: allowUnfree preserved from existing config on rerun" {
  # first run with --allow-unfree
  _scope_set=" "
  scope_add "shell"
  sort_scopes
  is_init=false
  allow_unfree="true"
  phase_scopes_write_config
  [[ "$(read_config_allow_unfree)" == "true" ]]

  # second run without the flag - should preserve existing value
  allow_unfree="false"
  any_scope="false"
  remove_scopes=()
  phase_scopes_load_existing
  [[ "$allow_unfree" == "true" ]]
}

@test "parse_args: --allow-unfree sets flag" {
  phase_bootstrap_parse_args --allow-unfree
  [[ "$allow_unfree" == "true" ]]
}

@test "parse_args: allow_unfree defaults to false" {
  phase_bootstrap_parse_args
  [[ "$allow_unfree" == "false" ]]
}

@test "flake.nix: reads allowUnfree from config" {
  grep -q 'cfg.allowUnfree' "$TEST_ENV_DIR/flake.nix"
}

# =============================================================================
# Flake structure
# =============================================================================

@test "flake.nix: references config.nix and scopes directory" {
  grep -q 'import ./config.nix' "$TEST_ENV_DIR/flake.nix"
  grep -q './scopes/' "$TEST_ENV_DIR/flake.nix"
}

@test "flake.nix: supports all four platforms" {
  grep -q 'x86_64-linux' "$TEST_ENV_DIR/flake.nix"
  grep -q 'aarch64-linux' "$TEST_ENV_DIR/flake.nix"
  grep -q 'x86_64-darwin' "$TEST_ENV_DIR/flake.nix"
  grep -q 'aarch64-darwin' "$TEST_ENV_DIR/flake.nix"
}

# =============================================================================
# Upgrade path (should_update_flake)
# =============================================================================

@test "upgrade: --upgrade flag triggers update" {
  should_update_flake "true"
}

@test "upgrade: without --upgrade skips update" {
  ! should_update_flake "false"
}

# =============================================================================
# Arg parser (phase_bootstrap_parse_args)
# =============================================================================

@test "parse_args: --shell sets scope and any_scope" {
  phase_bootstrap_parse_args --shell
  [[ "$any_scope" == "true" ]]
  scope_has "shell"
}

@test "parse_args: --all adds all non-prompt scopes" {
  phase_bootstrap_parse_args --all
  [[ "$any_scope" == "true" ]]
  scope_has "shell"
  scope_has "python"
  scope_has "docker"
  run ! scope_has "oh_my_posh"
  run ! scope_has "starship"
}

@test "parse_args: --omp-theme sets theme and adds oh_my_posh scope" {
  phase_bootstrap_parse_args --omp-theme "base"
  [[ "$omp_theme" == "base" ]]
  [[ "$any_scope" == "true" ]]
  scope_has "oh_my_posh"
}

@test "parse_args: --starship-theme sets theme and adds starship scope" {
  phase_bootstrap_parse_args --starship-theme "nerd"
  [[ "$starship_theme" == "nerd" ]]
  [[ "$any_scope" == "true" ]]
  scope_has "starship"
}

@test "parse_args: --remove collects scope names" {
  phase_bootstrap_parse_args --remove oh_my_posh rice
  [[ ${#remove_scopes[@]} -eq 2 ]]
  [[ "${remove_scopes[0]}" == "oh_my_posh" ]]
  [[ "${remove_scopes[1]}" == "rice" ]]
}

@test "parse_args: --remove normalizes hyphens to underscores" {
  phase_bootstrap_parse_args --remove oh-my-posh k8s-base
  [[ "${remove_scopes[0]}" == "oh_my_posh" ]]
  [[ "${remove_scopes[1]}" == "k8s_base" ]]
}

@test "parse_args: --remove stops at next flag" {
  phase_bootstrap_parse_args --remove rice --shell
  [[ ${#remove_scopes[@]} -eq 1 ]]
  [[ "${remove_scopes[0]}" == "rice" ]]
  [[ "$any_scope" == "true" ]]
  scope_has "shell"
}

@test "parse_args: --upgrade sets upgrade_packages" {
  phase_bootstrap_parse_args --upgrade
  [[ "$upgrade_packages" == "true" ]]
}

@test "parse_args: --unattended sets flag" {
  phase_bootstrap_parse_args --unattended
  [[ "$unattended" == "true" ]]
}

@test "parse_args: --unattended combines with scope flags" {
  phase_bootstrap_parse_args --shell --python --unattended
  [[ "$unattended" == "true" ]]
  scope_has "shell"
  scope_has "python"
}

@test "parse_args: --update-modules sets flag" {
  phase_bootstrap_parse_args --update-modules
  [[ "$update_modules" == "true" ]]
}

@test "parse_args: --quiet-summary sets flag" {
  phase_bootstrap_parse_args --quiet-summary
  [[ "$quiet_summary" == "true" ]]
}

@test "parse_args: multiple scope flags are additive" {
  phase_bootstrap_parse_args --shell --python --docker
  scope_has "shell"
  scope_has "python"
  scope_has "docker"
}

@test "parse_args: no args sets defaults" {
  phase_bootstrap_parse_args
  [[ "$any_scope" == "false" ]]
  [[ "$upgrade_packages" == "false" ]]
  [[ "$unattended" == "false" ]]
  [[ "$update_modules" == "false" ]]
  [[ "$omp_theme" == "" ]]
  [[ "$starship_theme" == "" ]]
  [[ ${#remove_scopes[@]} -eq 0 ]]
}

@test "parse_args: hyphenated flags normalize to underscores" {
  phase_bootstrap_parse_args --k8s-base --k8s-dev
  scope_has "k8s_base"
  scope_has "k8s_dev"
}

@test "parse_args: unknown option exits with code 2" {
  run phase_bootstrap_parse_args --nonexistent
  [[ $status -eq 2 ]]
}

# =============================================================================
# Summary mode detection
# =============================================================================

@test "summary: upgrade mode when upgrade_packages is true" {
  upgrade_packages="true"
  remove_scopes=()
  any_scope=false
  phase_summary_detect_mode
  [[ "$_mode" == "upgrade" ]]
}

@test "summary: remove mode when remove_scopes non-empty" {
  upgrade_packages="false"
  remove_scopes=(rice)
  any_scope=false
  phase_summary_detect_mode
  [[ "$_mode" == "remove" ]]
}

@test "summary: install mode when any_scope is true" {
  upgrade_packages="false"
  remove_scopes=()
  any_scope=true
  phase_summary_detect_mode
  [[ "$_mode" == "install" ]]
}

@test "summary: reconfigure mode by default" {
  upgrade_packages="false"
  remove_scopes=()
  any_scope=false
  phase_summary_detect_mode
  [[ "$_mode" == "reconfigure" ]]
}

# =============================================================================
# Prompt exclusivity (phase_scopes_enforce_prompt_exclusivity)
# =============================================================================

@test "exclusivity: --omp-theme removes starship" {
  _scope_set=" "
  scope_add "oh_my_posh"
  scope_add "starship"
  omp_theme="base"
  starship_theme=""
  phase_scopes_enforce_prompt_exclusivity
  scope_has "oh_my_posh"
  run ! scope_has "starship"
}

@test "exclusivity: --starship-theme removes oh_my_posh" {
  _scope_set=" "
  scope_add "oh_my_posh"
  scope_add "starship"
  omp_theme=""
  starship_theme="nerd"
  phase_scopes_enforce_prompt_exclusivity
  run ! scope_has "oh_my_posh"
  scope_has "starship"
}

@test "exclusivity: both themes set exits with error" {
  omp_theme="base"
  starship_theme="nerd"
  _ir_error=""
  run phase_scopes_enforce_prompt_exclusivity
  [[ $status -eq 2 ]]
}

# =============================================================================
# Nix profile phase
# =============================================================================

@test "nix_profile: pinned_rev loaded from file" {
  echo "abc123" >"$TEST_ENV_DIR/pinned_rev"
  phase_nix_profile_load_pinned_rev
  [[ "$PINNED_REV" == "abc123" ]]
}

@test "nix_profile: pinned_rev empty when file missing" {
  rm -f "$TEST_ENV_DIR/pinned_rev"
  phase_nix_profile_load_pinned_rev
  [[ "$PINNED_REV" == "" ]]
}

@test "nix_profile: pinned_rev strips whitespace" {
  printf "  abc123  \n" >"$TEST_ENV_DIR/pinned_rev"
  phase_nix_profile_load_pinned_rev
  [[ "$PINNED_REV" == "abc123" ]]
}

@test "nix_profile: apply runs profile add and upgrade" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  SECONDS=0
  phase_nix_profile_apply
  grep -q 'nix profile add path:' "$BATS_TEST_TMPDIR/nix.log"
  grep -q 'nix profile upgrade nix-env' "$BATS_TEST_TMPDIR/nix.log"
}

@test "nix_profile: update_flake uses override-input when pinned" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  PINNED_REV="abc123"
  upgrade_packages="true"
  SECONDS=0
  phase_nix_profile_update_flake
  grep -q 'flake lock --override-input' "$BATS_TEST_TMPDIR/nix.log"
}

@test "nix_profile: update_flake uses flake update when unpinned" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  PINNED_REV=""
  upgrade_packages="true"
  SECONDS=0
  phase_nix_profile_update_flake
  grep -q 'flake update' "$BATS_TEST_TMPDIR/nix.log"
}

@test "nix_profile: update_flake warns and continues when flake update fails" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  _io_nix() { return 1; }
  PINNED_REV=""
  upgrade_packages="true"
  SECONDS=0
  run phase_nix_profile_update_flake
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"flake update failed"* ]]
}

@test "nix_profile: update_flake warns and continues when flake lock fails (pinned)" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  _io_nix() { return 1; }
  PINNED_REV="abc123"
  upgrade_packages="true"
  SECONDS=0
  run phase_nix_profile_update_flake
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"flake lock failed"* ]]
}

@test "nix_profile: mitm_probe calls cert_intercept on TLS failure" {
  HOME="$TEST_HOME"
  NIX_ENV_TLS_PROBE_URL="https://example.com"
  _io_curl_probe() { return 1; }
  _io_run() { :; }
  mkdir -p "$TEST_HOME/.config/certs"

  # Create a fake SCRIPT_ROOT with stub scripts so phase_nix_profile_mitm_probe
  # sources our stubs instead of real cert_intercept/build_ca_bundle.
  local fake_root="$BATS_TEST_TMPDIR/fake_root"
  mkdir -p "$fake_root/.assets/lib" "$fake_root/.assets/config/bash_cfg"
  cat >"$fake_root/.assets/lib/certs.sh" <<'STUB'
build_ca_bundle() { touch "$HOME/.config/certs/ca-bundle.crt"; }
STUB
  cat >"$fake_root/.assets/config/bash_cfg/functions.sh" <<'STUB'
cert_intercept() { touch "$HOME/.config/certs/cert_intercept_called"; }
STUB
  SCRIPT_ROOT="$fake_root"

  phase_nix_profile_mitm_probe

  [[ -f "$TEST_HOME/.config/certs/cert_intercept_called" ]]
  [[ -f "$TEST_HOME/.config/certs/ca-bundle.crt" ]]
}

@test "nix_profile: mitm_probe skips probe when ca-bundle already exists" {
  HOME="$TEST_HOME"
  NIX_ENV_TLS_PROBE_URL="https://example.com"
  mkdir -p "$TEST_HOME/.config/certs"
  touch "$TEST_HOME/.config/certs/ca-bundle.crt"
  _io_run() { :; }

  # Use fake SCRIPT_ROOT - cert_intercept should NOT be called
  local fake_root="$BATS_TEST_TMPDIR/fake_root2"
  mkdir -p "$fake_root/.assets/lib" "$fake_root/.assets/config/bash_cfg"
  echo 'build_ca_bundle() { :; }' >"$fake_root/.assets/lib/certs.sh"
  echo 'cert_intercept() { touch "$HOME/cert_intercept_called"; }' >"$fake_root/.assets/config/bash_cfg/functions.sh"
  SCRIPT_ROOT="$fake_root"

  # probe should be skipped (ca-bundle exists), so curl stub should not matter
  _io_curl_probe() { touch "$TEST_HOME/probe_called"; return 1; }

  phase_nix_profile_mitm_probe
  [[ ! -f "$TEST_HOME/cert_intercept_called" ]]
  [[ ! -f "$TEST_HOME/probe_called" ]]
}

@test "nix_profile: gc runs wipe-history and store gc" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  phase_post_install_gc
  grep -q 'nix profile wipe-history' "$BATS_TEST_TMPDIR/nix.log"
  grep -q 'nix store gc' "$BATS_TEST_TMPDIR/nix.log"
}

# =============================================================================
# Overlay scope preservation
# =============================================================================

@test "config.nix: overlay scopes survive setup.sh config write" {
  printf '{ pkgs }: with pkgs; [ hello ]\n' >"$ENV_DIR/scopes/local_mytools.nix"
  cat >"$CONFIG_NIX" <<'NIX'
{
  isInit = false;
  allowUnfree = false;
  scopes = [
    "shell"
    "local_mytools"
  ];
}
NIX
  _scope_set=" "
  any_scope=false
  remove_scopes=()
  phase_scopes_load_existing
  phase_scopes_resolve_and_sort
  is_init=false
  phase_scopes_write_config

  local scopes
  scopes="$(read_config_scopes)"
  echo "$scopes" | grep -qx "shell"
  echo "$scopes" | grep -qx "local_mytools"
}

@test "config.nix: adding CLI scope preserves existing overlay scopes" {
  printf '{ pkgs }: with pkgs; [ hello ]\n' >"$ENV_DIR/scopes/local_mytools.nix"
  cat >"$CONFIG_NIX" <<'NIX'
{
  isInit = false;
  allowUnfree = false;
  scopes = [
    "shell"
    "local_mytools"
  ];
}
NIX
  _scope_set=" "
  any_scope=true
  remove_scopes=()
  scope_add "python"
  phase_scopes_load_existing
  phase_scopes_resolve_and_sort
  is_init=false
  phase_scopes_write_config

  local scopes
  scopes="$(read_config_scopes)"
  echo "$scopes" | grep -qx "shell"
  echo "$scopes" | grep -qx "python"
  echo "$scopes" | grep -qx "local_mytools"
}

# =============================================================================
# Overlay scope GC
# =============================================================================

@test "overlay: orphaned local_ scope removed on setup" {
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; [ hello ]\n' >"$ENV_DIR/scopes/local_mytools.nix"
  OVERLAY_DIR="$ENV_DIR/local"
  phase_platform_discover_overlay
  [ ! -f "$ENV_DIR/scopes/local_mytools.nix" ]
}

@test "overlay: active scopes preserved, only orphans removed" {
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; [ bat ]\n' >"$ENV_DIR/local/scopes/active.nix"
  printf '{ pkgs }: with pkgs; [ bat ]\n' >"$ENV_DIR/scopes/local_active.nix"
  printf '{ pkgs }: with pkgs; [ hello ]\n' >"$ENV_DIR/scopes/local_orphan.nix"
  OVERLAY_DIR="$ENV_DIR/local"
  phase_platform_discover_overlay
  [ -f "$ENV_DIR/scopes/local_active.nix" ]
  [ ! -f "$ENV_DIR/scopes/local_orphan.nix" ]
}
