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

# Write a minimal flake.lock whose nixpkgs node carries `lastModified` - the
# field the no-downgrade comparison orders revisions by.
_write_flake_lock() {
  cat >"$TEST_ENV_DIR/flake.lock" <<EOF
{
  "nodes": {
    "nixpkgs": {
      "locked": {
        "lastModified": $1,
        "rev": "locked000"
      }
    }
  }
}
EOF
}

# Write the repo-validated revision file that phase_bootstrap_sync_env_dir
# copies into ENV_DIR.
_write_validated_rev() {
  cat >"$TEST_ENV_DIR/nixpkgs_rev.json" <<EOF
{
  "rev": "$1",
  "lastModified": $2
}
EOF
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
  # nix_profile phase resolves the nixpkgs revision through nx_rev.sh,
  # which it sources from SCRIPT_ROOT.
  SCRIPT_ROOT="$REPO_ROOT"
  # shellcheck source=../../.assets/lib/nx_rev.sh
  source "$REPO_ROOT/.assets/lib/nx_rev.sh"
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
  DEV_ENV_DIR="$TEST_HOME/.config/dev-env"
  mkdir -p "$DEV_ENV_DIR"
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
  # gcloud is installed via the official tarball (see nix/configure/gcloud.sh),
  # so the scope file is intentionally empty (carries the
  # `# bins: (external-installer)` sentinel only).
  local config_only_scopes=" conda docker distrobox gcloud "
  for sc in "${VALID_SCOPES[@]}"; do
    local nix_file="$TEST_ENV_DIR/scopes/${sc}.nix"
    # some scopes have no .nix file (handled by builtins.pathExists in flake)
    [[ -f "$nix_file" ]] || continue
    if [[ "$config_only_scopes" == *" $sc "* ]]; then
      continue
    fi
    local pkg_count
    pkg_count="$(_scope_pkgs "$nix_file" | wc -l)"
    [[ $pkg_count -gt 0 ]] || {
      echo "empty scope file: $nix_file" >&2
      false
    }
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

@test "system-prefer: pwsh always kept (always-nix tier)" {
  _scope_set=" "
  scope_add "shell"
  scope_add "pwsh"
  uname() { echo "Linux"; }
  has_system_cmd() { return 0; }
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
  # phase_scopes_skip_system_prefer's "not installed anywhere" branch checks
  # both `has_system_cmd zsh` (system pkg manager copy) AND `command -v zsh`
  # (anything on PATH including /nix). Stub both so the test runs
  # deterministically on any host - including developer machines with zsh
  # installed via nix - instead of skipping based on host state.
  has_system_cmd() { return 1; }
  command() {
    if [ "$1" = "-v" ] && [ "$2" = "zsh" ]; then
      return 1
    fi
    builtin command "$@"
  }
  phase_scopes_skip_system_prefer
  run ! scope_has "zsh"
  scope_has "shell"
}

@test "system-prefer: zsh removed on Linux when system-wide (pwsh stays - always-nix)" {
  _scope_set=" "
  scope_add "shell"
  scope_add "pwsh"
  scope_add "zsh"
  uname() { echo "Linux"; }
  has_system_cmd() { return 0; }
  phase_scopes_skip_system_prefer
  scope_has "pwsh"
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

@test "parse_args: --upgrade is accepted with a deprecation warning" {
  run phase_bootstrap_parse_args --upgrade
  [[ $status -eq 0 ]]
  [[ "$output" == *"default now"* ]]
}

@test "parse_args: --register-ssh-key is accepted with a deprecation warning" {
  run phase_bootstrap_parse_args --register-ssh-key
  [[ $status -eq 0 ]]
  [[ "$output" == *"default now"* ]]
}

@test "parse_args: --latest sets upgrade_latest" {
  phase_bootstrap_parse_args --latest
  [[ "$upgrade_latest" == "true" ]]
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
  [[ "$upgrade_latest" == "false" ]]
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

@test "summary: upgrade mode by default" {
  remove_scopes=()
  any_scope=false
  phase_summary_detect_mode
  [[ "$_mode" == "upgrade" ]]
}

@test "summary: remove mode when remove_scopes non-empty" {
  remove_scopes=(rice)
  any_scope=false
  phase_summary_detect_mode
  [[ "$_mode" == "remove" ]]
}

@test "summary: install mode when any_scope is true" {
  remove_scopes=()
  any_scope=true
  phase_summary_detect_mode
  [[ "$_mode" == "install" ]]
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

@test "nix_profile: rev ladder picks the user pin first" {
  echo "abc123" >"$TEST_ENV_DIR/pinned_rev"
  _write_validated_rev def456 2000000000
  phase_nix_profile_load_rev
  [[ "$NX_REV_MODE" == "pinned" ]]
  [[ "$NX_REV_SHA" == "abc123" ]]
}

@test "nix_profile: rev ladder falls to the validated rev when unpinned" {
  rm -f "$TEST_ENV_DIR/pinned_rev"
  _write_validated_rev def456 2000000000
  phase_nix_profile_load_rev
  [[ "$NX_REV_MODE" == "validated" ]]
  [[ "$NX_REV_SHA" == "def456" ]]
}

@test "nix_profile: rev ladder honours --latest over the validated rev" {
  rm -f "$TEST_ENV_DIR/pinned_rev"
  _write_validated_rev def456 2000000000
  upgrade_latest="true"
  phase_nix_profile_load_rev
  [[ "$NX_REV_MODE" == "latest" ]]
  [[ "$NX_REV_SHA" == "" ]]
}

@test "nix_profile: rev ladder reports none when no rev file is synced" {
  rm -f "$TEST_ENV_DIR/pinned_rev" "$TEST_ENV_DIR/nixpkgs_rev.json"
  upgrade_latest="false"
  phase_nix_profile_load_rev
  [[ "$NX_REV_MODE" == "none" ]]
}

@test "nix_profile: rev ladder strips whitespace from the pin" {
  printf "  abc123  \n" >"$TEST_ENV_DIR/pinned_rev"
  phase_nix_profile_load_rev
  [[ "$NX_REV_SHA" == "abc123" ]]
}

@test "nix_profile: apply runs profile add and upgrade" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  SECONDS=0
  phase_nix_profile_apply
  grep -q 'nix profile add path:' "$BATS_TEST_TMPDIR/nix.log"
  grep -q 'nix profile upgrade nix-env' "$BATS_TEST_TMPDIR/nix.log"
}

@test "nix_profile: apply skips upgrade when narHash matches last-applied" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  # Pretend nix-env is already installed so we don't take the add branch.
  _io_nix() {
    case "$*" in
    'profile list --json') echo '{"elements":[{"originalUrl":"path:.../nix-env"}]}' ;;
    'flake metadata '*' --json') echo '{"locked":{"narHash":"sha256-FAKE"}}' ;;
    *) echo "nix $*" >>"$BATS_TEST_TMPDIR/nix.log" ;;
    esac
  }
  command -v jq >/dev/null 2>&1 || skip "jq required for narHash extraction"
  mkdir -p "$DEV_ENV_DIR"
  echo "sha256-FAKE" >"$DEV_ENV_DIR/last-applied-narhash"
  SECONDS=0
  run phase_nix_profile_apply
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"narHash unchanged"* ]]
  ! grep -q 'nix profile upgrade nix-env' "$BATS_TEST_TMPDIR/nix.log"
}

@test "nix_profile: apply runs upgrade when narHash differs from last-applied" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  _io_nix() {
    case "$*" in
    'profile list --json') echo '{"elements":[{"originalUrl":"path:.../nix-env"}]}' ;;
    'flake metadata '*' --json') echo '{"locked":{"narHash":"sha256-NEW"}}' ;;
    *) echo "nix $*" >>"$BATS_TEST_TMPDIR/nix.log" ;;
    esac
  }
  command -v jq >/dev/null 2>&1 || skip "jq required for narHash extraction"
  mkdir -p "$DEV_ENV_DIR"
  echo "sha256-OLD" >"$DEV_ENV_DIR/last-applied-narhash"
  SECONDS=0
  phase_nix_profile_apply
  grep -q 'nix profile upgrade nix-env' "$BATS_TEST_TMPDIR/nix.log"
  [[ "$(cat "$DEV_ENV_DIR/last-applied-narhash")" == "sha256-NEW" ]]
}

@test "nix_profile: update_flake backs up the lock and apply discards it on success" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  _write_flake_lock 1000000000
  NX_REV_MODE="pinned"
  NX_REV_SHA="abc123"
  SECONDS=0
  phase_nix_profile_update_flake
  [[ -f "$NX_LOCK_BACKUP" ]]
  local _bak="$NX_LOCK_BACKUP"
  phase_nix_profile_apply
  [[ -z "$NX_LOCK_BACKUP" ]]
  [[ ! -f "$_bak" ]]
}

@test "nix_profile: a failed apply keeps the lock backup for the EXIT trap to restore" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  _write_flake_lock 1000000000
  local _before
  _before="$(cat "$TEST_ENV_DIR/flake.lock")"
  NX_REV_MODE="pinned"
  NX_REV_SHA="abc123"
  phase_nix_profile_update_flake
  _write_flake_lock 2000000000
  _io_nix() {
    case "$*" in
    'profile upgrade'*) return 1 ;;
    esac
  }
  SECONDS=0
  run phase_nix_profile_apply
  [[ "$status" -eq 1 ]]
  [[ -f "$NX_LOCK_BACKUP" ]]
  _nx_lock_restore "$TEST_ENV_DIR" "$NX_LOCK_BACKUP"
  [[ "$(cat "$TEST_ENV_DIR/flake.lock")" == "$_before" ]]
}

@test "nix_profile: update_flake uses override-input when pinned" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  _write_flake_lock 1000000000
  NX_REV_MODE="pinned"
  NX_REV_SHA="abc123"
  SECONDS=0
  phase_nix_profile_update_flake
  grep -q 'flake lock --override-input' "$BATS_TEST_TMPDIR/nix.log"
}

@test "nix_profile: update_flake locks the validated rev" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  _write_flake_lock 1000000000
  _write_validated_rev def456 2000000000
  NX_REV_MODE="validated"
  NX_REV_SHA="def456"
  SECONDS=0
  phase_nix_profile_update_flake
  grep -q 'flake lock --override-input nixpkgs github:nixos/nixpkgs/def456' "$BATS_TEST_TMPDIR/nix.log"
}

@test "nix_profile: update_flake refuses to downgrade to an older validated rev" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  # locked is NEWER than validated - the shape after `nx upgrade --latest`
  # while the CI bump is lagging behind.
  _write_flake_lock 2000000000
  _write_validated_rev def456 1000000000
  NX_REV_MODE="validated"
  NX_REV_SHA="def456"
  SECONDS=0
  run phase_nix_profile_update_flake
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"already at or ahead"* ]]
  [[ ! -s "$BATS_TEST_TMPDIR/nix.log" ]]
}

@test "nix_profile: update_flake uses flake update for --latest" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  _write_flake_lock 1000000000
  NX_REV_MODE="latest"
  NX_REV_SHA=""
  SECONDS=0
  phase_nix_profile_update_flake
  grep -q 'flake update' "$BATS_TEST_TMPDIR/nix.log"
}

@test "nix_profile: update_flake keeps the lock when no validated rev exists" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  _write_flake_lock 1000000000
  NX_REV_MODE="none"
  NX_REV_SHA=""
  SECONDS=0
  run phase_nix_profile_update_flake
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"no validated nixpkgs revision"* ]]
  [[ ! -s "$BATS_TEST_TMPDIR/nix.log" ]]
}

@test "nix_profile: update_flake locks the validated rev on a first run" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  # No flake.lock: `nix profile add` would otherwise resolve unstable HEAD and
  # write a lock naming a revision no CI has built.
  rm -f "$TEST_ENV_DIR/flake.lock"
  _write_validated_rev def456 2000000000
  NX_REV_MODE="validated"
  NX_REV_SHA="def456"
  SECONDS=0
  phase_nix_profile_update_flake
  grep -q 'flake lock --override-input nixpkgs github:nixos/nixpkgs/def456' "$BATS_TEST_TMPDIR/nix.log"
}

@test "nix_profile: update_flake warns and continues when flake update fails" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  _write_flake_lock 1000000000
  _io_nix() { return 1; }
  NX_REV_MODE="latest"
  NX_REV_SHA=""
  SECONDS=0
  run phase_nix_profile_update_flake
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"flake update failed"* ]]
}

@test "nix_profile: update_flake warns and continues when flake lock fails (pinned)" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  _write_flake_lock 1000000000
  _io_nix() { return 1; }
  NX_REV_MODE="pinned"
  NX_REV_SHA="abc123"
  SECONDS=0
  run phase_nix_profile_update_flake
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"flake lock failed"* ]]
}

@test "nix_profile: mitm_probe calls cert_intercept on TLS failure (cert cause confirmed by bypass probe)" {
  HOME="$TEST_HOME"
  NIX_ENV_TLS_PROBE_URL="https://example.com"
  _io_curl_probe() { return 1; }
  _io_curl_probe_insecure() { return 0; } # bypass probe succeeds -> cert was the cause
  _io_run() { :; }
  mkdir -p "$TEST_HOME/.config/certs"

  # Create a fake SCRIPT_ROOT with a stub certs.sh that defines BOTH
  # build_ca_bundle AND cert_intercept (the latter was moved from
  # functions.sh to certs.sh; phase_nix_profile_mitm_probe no longer
  # sources functions.sh wholesale).
  local fake_root="$BATS_TEST_TMPDIR/fake_root"
  mkdir -p "$fake_root/.assets/lib"
  cat >"$fake_root/.assets/lib/certs.sh" <<'STUB'
build_ca_bundle() { touch "$HOME/.config/certs/ca-bundle.crt"; }
cert_intercept() { touch "$HOME/.config/certs/cert_intercept_called"; }
STUB
  SCRIPT_ROOT="$fake_root"

  phase_nix_profile_mitm_probe

  [[ -f "$TEST_HOME/.config/certs/cert_intercept_called" ]]
  [[ -f "$TEST_HOME/.config/certs/ca-bundle.crt" ]]
}

@test "nix_profile: mitm_probe skips cert_intercept when bypass probe also fails (network/DNS, not cert)" {
  HOME="$TEST_HOME"
  NIX_ENV_TLS_PROBE_URL="https://example.com"
  _io_curl_probe() { return 1; }
  _io_curl_probe_insecure() { return 1; } # bypass also fails -> not a cert problem
  _io_run() { :; }
  mkdir -p "$TEST_HOME/.config/certs"

  local fake_root="$BATS_TEST_TMPDIR/fake_root_netfail"
  mkdir -p "$fake_root/.assets/lib"
  cat >"$fake_root/.assets/lib/certs.sh" <<'STUB'
build_ca_bundle() { touch "$HOME/.config/certs/ca-bundle.crt"; }
cert_intercept() { touch "$HOME/.config/certs/cert_intercept_called"; }
STUB
  SCRIPT_ROOT="$fake_root"

  run phase_nix_profile_mitm_probe

  # cert_intercept must NOT have been called - that's the whole point
  [[ ! -f "$TEST_HOME/.config/certs/cert_intercept_called" ]]
  # ca-bundle.crt IS built unconditionally now (not gated on MITM detection),
  # so the bundle exists even when the probe is skipped for network reasons.
  [[ -f "$TEST_HOME/.config/certs/ca-bundle.crt" ]]
  # the warning explaining the skip should be visible
  [[ "$output" == *"non-cert reason"* ]]
}

@test "nix_profile: mitm_probe skips probe when ca-custom.crt already exists" {
  HOME="$TEST_HOME"
  NIX_ENV_TLS_PROBE_URL="https://example.com"
  mkdir -p "$TEST_HOME/.config/certs"
  # Probe is gated on ca-custom.crt (the cause), not ca-bundle.crt (the
  # derivative). When ca-custom.crt exists, MITM was already handled and
  # we shouldn't re-probe or re-intercept.
  touch "$TEST_HOME/.config/certs/ca-custom.crt"
  _io_run() { :; }

  # Use fake SCRIPT_ROOT - cert_intercept should NOT be called
  local fake_root="$BATS_TEST_TMPDIR/fake_root2"
  mkdir -p "$fake_root/.assets/lib"
  cat >"$fake_root/.assets/lib/certs.sh" <<'STUB'
build_ca_bundle() { touch "$HOME/.config/certs/ca-bundle.crt"; }
cert_intercept() { touch "$HOME/cert_intercept_called"; }
STUB
  SCRIPT_ROOT="$fake_root"

  # probe should be skipped (ca-custom.crt exists), so curl stub should not matter
  _io_curl_probe() {
    touch "$TEST_HOME/probe_called"
    return 1
  }

  phase_nix_profile_mitm_probe
  [[ ! -f "$TEST_HOME/cert_intercept_called" ]]
  [[ ! -f "$TEST_HOME/probe_called" ]]
  # build_ca_bundle still runs unconditionally
  [[ -f "$TEST_HOME/.config/certs/ca-bundle.crt" ]]
}

@test "nix_profile: mitm_probe rebuilds ca-bundle.crt after cert_intercept (macOS Keychain merge path)" {
  HOME="$TEST_HOME"
  NIX_ENV_TLS_PROBE_URL="https://example.com"
  _io_curl_probe() { return 1; }
  _io_curl_probe_insecure() { return 0; } # bypass succeeds -> MITM detected
  _io_run() { :; }
  mkdir -p "$TEST_HOME/.config/certs"

  # Stub build_ca_bundle to count invocations - it must run twice (once
  # before the probe, once after cert_intercept produces ca-custom.crt) so
  # the macOS Keychain dump gets the freshly intercepted certs appended.
  # cert_intercept lives in certs.sh now (post-F-017 move from functions.sh).
  local fake_root="$BATS_TEST_TMPDIR/fake_root_rebuild"
  mkdir -p "$fake_root/.assets/lib"
  cat >"$fake_root/.assets/lib/certs.sh" <<'STUB'
build_ca_bundle() {
  local _counter="$HOME/.config/certs/build_count"
  if [ -f "$_counter" ]; then
    printf '%s' "$(($(cat "$_counter") + 1))" >"$_counter"
  else
    printf '1' >"$_counter"
  fi
  touch "$HOME/.config/certs/ca-bundle.crt"
}
cert_intercept() { touch "$HOME/.config/certs/ca-custom.crt"; }
STUB
  SCRIPT_ROOT="$fake_root"

  phase_nix_profile_mitm_probe
  [[ "$(cat "$TEST_HOME/.config/certs/build_count")" = "2" ]]
}

@test "bootstrap: ensure_certs builds ca-bundle.crt before nix operations" {
  HOME="$TEST_HOME"
  mkdir -p "$TEST_HOME/.config/certs"

  local fake_root="$BATS_TEST_TMPDIR/fake_root_ensure"
  mkdir -p "$fake_root/.assets/lib"
  echo 'merge_local_certs() { :; }; build_ca_bundle() { touch "$HOME/.config/certs/ca-bundle.crt"; }' >"$fake_root/.assets/lib/certs.sh"
  SCRIPT_ROOT="$fake_root"

  phase_bootstrap_ensure_certs
  [[ -f "$TEST_HOME/.config/certs/ca-bundle.crt" ]]
}

@test "bootstrap: ensure_certs unsets NIX_SSL_CERT_FILE when it points to a missing file" {
  HOME="$TEST_HOME"
  # Simulate the broken state: shell-exported env var pointing to a file
  # the user just deleted. Without ensure_certs's self-heal, the next
  # nix operation would inherit the bad path and abort.
  export NIX_SSL_CERT_FILE="$TEST_HOME/.config/certs/ca-bundle.crt"
  export SSL_CERT_FILE="$TEST_HOME/.config/certs/ca-bundle.crt"

  local fake_root="$BATS_TEST_TMPDIR/fake_root_selfheal"
  mkdir -p "$fake_root/.assets/lib"
  # Stub build_ca_bundle as a no-op (simulating an unsupported distro
  # where neither /etc/ssl/certs/* nor security exist) so the file stays
  # missing - the self-heal branch is what we want to exercise.
  echo 'merge_local_certs() { :; }; build_ca_bundle() { :; }' >"$fake_root/.assets/lib/certs.sh"
  SCRIPT_ROOT="$fake_root"

  run phase_bootstrap_ensure_certs
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"NIX_SSL_CERT_FILE"* ]]
  [[ "$output" == *"missing file"* ]]
  # Re-enter to verify the unset stuck (the run subshell loses the unset,
  # so directly invoke the function in the parent shell).
  phase_bootstrap_ensure_certs >/dev/null 2>&1
  [[ -z "${NIX_SSL_CERT_FILE:-}" ]]
  [[ -z "${SSL_CERT_FILE:-}" ]]
}

@test "bootstrap: ensure_certs leaves valid NIX_SSL_CERT_FILE alone" {
  HOME="$TEST_HOME"
  mkdir -p "$TEST_HOME/.config/certs"
  # Valid existing file - self-heal must NOT fire.
  touch "$TEST_HOME/.config/certs/ca-bundle.crt"
  export NIX_SSL_CERT_FILE="$TEST_HOME/.config/certs/ca-bundle.crt"

  local fake_root="$BATS_TEST_TMPDIR/fake_root_keep"
  mkdir -p "$fake_root/.assets/lib"
  echo 'merge_local_certs() { :; }; build_ca_bundle() { :; }' >"$fake_root/.assets/lib/certs.sh"
  SCRIPT_ROOT="$fake_root"

  phase_bootstrap_ensure_certs
  [[ "$NIX_SSL_CERT_FILE" = "$TEST_HOME/.config/certs/ca-bundle.crt" ]]
}

@test "nix_profile: gc runs wipe-history and store gc" {
  : >"$BATS_TEST_TMPDIR/nix.log"
  phase_post_install_gc
  grep -q 'nix profile wipe-history' "$BATS_TEST_TMPDIR/nix.log"
  grep -q 'nix store gc' "$BATS_TEST_TMPDIR/nix.log"
}

@test "post_install: gc sweeps stale shell caches after nix store gc" {
  HOME="$TEST_HOME"
  mkdir -p "$TEST_HOME/.cache/powershell" "$TEST_HOME/.cache/oh-my-posh"
  : >"$TEST_HOME/.cache/powershell/ModuleAnalysisCache-DEAD"
  : >"$TEST_HOME/.cache/powershell/StartupProfileData-Interactive"
  : >"$TEST_HOME/.cache/powershell/PowerShellGet" # unrelated, must be kept
  : >"$TEST_HOME/.cache/oh-my-posh/init.42.sh"
  : >"$TEST_HOME/.cache/oh-my-posh/init.43.ps1"
  : >"$TEST_HOME/.cache/oh-my-posh/init.44.zsh"         # zsh init does NOT embed path - keep
  : >"$TEST_HOME/.cache/oh-my-posh/segment-1.omp.cache" # unrelated, must be kept

  phase_post_install_gc

  [[ ! -e "$TEST_HOME/.cache/powershell/ModuleAnalysisCache-DEAD" ]]
  [[ ! -e "$TEST_HOME/.cache/powershell/StartupProfileData-Interactive" ]]
  [[ -e "$TEST_HOME/.cache/powershell/PowerShellGet" ]]
  [[ ! -e "$TEST_HOME/.cache/oh-my-posh/init.42.sh" ]]
  [[ ! -e "$TEST_HOME/.cache/oh-my-posh/init.43.ps1" ]]
  [[ -e "$TEST_HOME/.cache/oh-my-posh/init.44.zsh" ]]
  [[ -e "$TEST_HOME/.cache/oh-my-posh/segment-1.omp.cache" ]]
}

@test "post_install: gc is silent when cache dirs are absent" {
  HOME="$TEST_HOME"
  [[ ! -d "$TEST_HOME/.cache/powershell" ]]
  [[ ! -d "$TEST_HOME/.cache/oh-my-posh" ]]
  run phase_post_install_gc
  [ "$status" -eq 0 ]
  [[ "$output" != *"stale shell cache"* ]]
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

# =============================================================================
# Overlays as the org extension point (decision 0013)
# =============================================================================

# Org overlay at $ORG with scope `team` whose header names $1 (may be empty).
_org_overlay() {
  ORG="$TEST_HOME/org-overlay"
  mkdir -p "$ORG/scopes"
  {
    [ -n "${1:-}" ] && printf '# scopes: %s\n' "$1"
    printf '{ pkgs }: with pkgs; [ btop ]\n'
  } >"$ORG/scopes/team.nix"
  export NIX_ENV_OVERLAY_DIR="$ORG"
}

# One setup pass over the scope phases, flags in $@ as parse_args leaves them.
_overlay_setup_pass() {
  _scope_set=" "
  local s
  for s in "$@"; do scope_add "$s"; done
  _cli_scope_set="$_scope_set"
  any_scope=false
  [ $# -gt 0 ] && any_scope=true
  remove_scopes=("${OVERLAY_REMOVE[@]}")
  phase_platform_discover_overlay
  phase_scopes_load_existing
  phase_scopes_apply_overlay
  phase_scopes_apply_removes
  phase_scopes_resolve_and_sort
  is_init=false
  phase_scopes_write_config
  phase_scopes_save_overlay_state
}

@test "overlay: org and personal overlays both sync, org listed first" {
  _org_overlay
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; [ hello ]\n' >"$ENV_DIR/local/scopes/mine.nix"
  phase_platform_discover_overlay
  [ "$OVERLAY_DIR" = "$ORG:$ENV_DIR/local" ]
  [ -f "$ENV_DIR/scopes/local_team.nix" ]
  [ -f "$ENV_DIR/scopes/local_mine.nix" ]
  [[ "$overlay_entries" == *"org local_team $ORG/scopes/team.nix"* ]]
  [[ "$overlay_entries" == *"local local_mine $ENV_DIR/local/scopes/mine.nix"* ]]
}

@test "overlay: on a name clash the org file wins with a warning" {
  _org_overlay
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/local/scopes/team.nix"
  run phase_platform_discover_overlay
  [[ "$output" == *"$ENV_DIR/local/scopes/team.nix ignored - the organization overlay provides team"* ]]
  phase_platform_discover_overlay 2>/dev/null
  cmp -s "$ORG/scopes/team.nix" "$ENV_DIR/scopes/local_team.nix"
}

@test "overlay: header scopes are recorded and unknown names warn" {
  _org_overlay "gcloud k8s-base nosuchscope"
  run phase_platform_discover_overlay
  [[ "$output" == *"unknown scope 'nosuchscope'"* ]]
  phase_platform_discover_overlay 2>/dev/null
  [[ "$overlay_entries" == *"org gcloud $ORG/scopes/team.nix"* ]]
  [[ "$overlay_entries" == *"org k8s_base $ORG/scopes/team.nix"* ]]
  [[ "$overlay_entries" != *"nosuchscope"* ]]
}

@test "overlay: a flagless run enables overlay scopes and header scopes" {
  _org_overlay "gcloud k8s_base"
  _overlay_setup_pass
  local scopes
  scopes="$(read_config_scopes)"
  echo "$scopes" | grep -qx "local_team"
  echo "$scopes" | grep -qx "gcloud"
  echo "$scopes" | grep -qx "k8s_base"
}

@test "overlay: deleting the overlay file drops its scope from config.nix" {
  _org_overlay
  _overlay_setup_pass
  read_config_scopes | grep -qx "local_team"
  rm "$ORG/scopes/team.nix"
  _overlay_setup_pass
  [ "$(read_config_scopes | grep -cx local_team)" -eq 0 ]
  [ ! -f "$ENV_DIR/scopes/local_team.nix" ]
}

@test "overlay: --remove of an org scope file by its plain name is refused, other removals go on" {
  _org_overlay
  _overlay_setup_pass python
  OVERLAY_REMOVE=(team python)
  run _overlay_setup_pass
  [ "$status" -eq 0 ]
  [[ "$output" == *"team is controlled by the organization overlay ($ORG/scopes/team.nix) - not removed"* ]]
  read_config_scopes | grep -qx local_team
  run read_config_scopes
  [[ "$output" != *python* ]]
}

@test "overlay: --remove of a hyphenated org scope file is refused" {
  _org_overlay
  mv "$ORG/scopes/team.nix" "$ORG/scopes/data-tools.nix"
  _overlay_setup_pass
  OVERLAY_REMOVE=(data_tools)
  run _overlay_setup_pass
  [ "$status" -eq 0 ]
  [[ "$output" == *"data_tools is controlled by the organization overlay ($ORG/scopes/data-tools.nix) - not removed"* ]]
}

@test "overlay: --remove of a header scope is refused" {
  _org_overlay "gcloud"
  _overlay_setup_pass
  OVERLAY_REMOVE=(gcloud)
  run _overlay_setup_pass
  [[ "$output" == *"gcloud is controlled by the organization overlay ($ORG/scopes/team.nix) - not removed"* ]]
  OVERLAY_REMOVE=(gcloud)
  _overlay_setup_pass 2>/dev/null
  read_config_scopes | grep -qx "gcloud"
  [ ! -s "$BATS_TEST_TMPDIR/run.log" ] || ! grep -q gcloud_remove "$BATS_TEST_TMPDIR/run.log"
}

@test "overlay: a scope dropped from the header is removed once" {
  _org_overlay "gcloud"
  _overlay_setup_pass
  printf '{ pkgs }: with pkgs; [ btop ]\n' >"$ORG/scopes/team.nix"
  _overlay_setup_pass
  [ "$(read_config_scopes | grep -cx gcloud)" -eq 0 ]
  grep -q "gcloud_remove.sh" "$BATS_TEST_TMPDIR/run.log"
  # the user adds it back; later runs keep it
  _overlay_setup_pass gcloud
  _overlay_setup_pass
  read_config_scopes | grep -qx "gcloud"
  [ "$(grep -c gcloud_remove.sh "$BATS_TEST_TMPDIR/run.log")" -eq 1 ]
}

@test "overlay: an invalid --remove name does not lose a once-only header removal" {
  _org_overlay "gcloud"
  _overlay_setup_pass
  printf '{ pkgs }: with pkgs; [ btop ]\n' >"$ORG/scopes/team.nix"
  OVERLAY_REMOVE=(nosuchscope)
  run _overlay_setup_pass
  [ "$status" -eq 2 ]
  OVERLAY_REMOVE=()
  _overlay_setup_pass
  [ "$(read_config_scopes | grep -cx gcloud)" -eq 0 ]
}

@test "overlay: a scope file name with unsafe characters is skipped with a warning" {
  _org_overlay
  printf '{ pkgs }: with pkgs; [ hello ]\n' >"$ORG/scopes/team tools.nix"
  printf '{ pkgs }: with pkgs; [ hello ]\n' >"$ORG/scopes/team\".nix"
  run phase_platform_discover_overlay
  [[ "$output" == *"team tools.nix ignored - scope file names may use only letters, digits, - and _"* ]]
  [[ "$output" == *"team\".nix ignored"* ]]
  [ ! -f "$ENV_DIR/scopes/local_team tools.nix" ]
  [ ! -f "$ENV_DIR/scopes/local_team\".nix" ]
}

@test "overlay: a dropped header scope another scope depends on is not removed" {
  _org_overlay "az python"
  _overlay_setup_pass
  printf '# scopes: az\n{ pkgs }: with pkgs; [ btop ]\n' >"$ORG/scopes/team.nix"
  _overlay_setup_pass
  read_config_scopes | grep -qx "python"
  [ ! -f "$BATS_TEST_TMPDIR/run.log" ] || [ "$(grep -c python_remove.sh "$BATS_TEST_TMPDIR/run.log")" -eq 0 ]
}

@test "overlay: dropping a scope and its dependent together removes both" {
  _org_overlay "az python"
  _overlay_setup_pass
  printf '{ pkgs }: with pkgs; [ btop ]\n' >"$ORG/scopes/team.nix"
  _overlay_setup_pass
  [ "$(read_config_scopes | grep -cxE 'az|python')" -eq 0 ]
  grep -q python_remove.sh "$BATS_TEST_TMPDIR/run.log"
}

@test "overlay: a dropped dependency goes when --remove takes its dependent" {
  _org_overlay "az python"
  _overlay_setup_pass
  printf '{ pkgs }: with pkgs; [ btop ]\n' >"$ORG/scopes/team.nix"
  OVERLAY_REMOVE=(az)
  _overlay_setup_pass
  [ "$(read_config_scopes | grep -cxE 'az|python')" -eq 0 ]
  grep -q python_remove.sh "$BATS_TEST_TMPDIR/run.log"
}

@test "overlay: hooks also find fnm's Node in ~/.fnm and on macOS" {
  _org_overlay
  mkdir -p "$ORG/hooks/post-setup.d"
  printf 'printf "%%s\\n" "$PATH"\n' >"$ORG/hooks/post-setup.d/10-path.sh"
  phase_platform_discover_overlay >/dev/null 2>&1
  unset FNM_DIR
  HOME="$TEST_HOME" run phase_platform_run_overlay_hooks
  [[ "$output" == *"$TEST_HOME/.fnm/aliases/default/bin:"* ]]
  [[ "$output" == *"$TEST_HOME/Library/Application Support/fnm/aliases/default/bin:"* ]]
}

@test "overlay: hooks find fnm's Node under XDG_DATA_HOME" {
  _org_overlay
  mkdir -p "$ORG/hooks/post-setup.d"
  printf 'printf "%%s\\n" "$PATH"\n' >"$ORG/hooks/post-setup.d/10-path.sh"
  phase_platform_discover_overlay >/dev/null 2>&1
  unset FNM_DIR
  XDG_DATA_HOME="$TEST_HOME/xdg" run phase_platform_run_overlay_hooks
  [[ "$output" == *"$TEST_HOME/xdg/fnm/aliases/default/bin:"* ]]
}

@test "overlay: a glob in the header is an unknown name, not a file match" {
  _org_overlay "*"
  mkdir -p "$TEST_HOME/cwd" && touch "$TEST_HOME/cwd/gcloud"
  cd "$TEST_HOME/cwd"
  run phase_platform_discover_overlay
  [[ "$output" == *"unknown scope '*'"* ]]
  phase_platform_discover_overlay 2>/dev/null
  [[ "$overlay_entries" != *" gcloud "* ]]
}

@test "overlay: a missing org overlay folder stops setup and deletes nothing" {
  _org_overlay "gcloud"
  _overlay_setup_pass
  mv "$ORG" "$ORG.away"
  run phase_platform_discover_overlay
  [ "$status" -eq 1 ]
  [[ "$output" == *"organization overlay $ORG (from NIX_ENV_OVERLAY_DIR) is not a readable directory"* ]]
  [ -f "$ENV_DIR/scopes/local_team.nix" ]
  grep -q "org gcloud" "$ENV_DIR/overlay_scopes"
}

@test "overlay: an unreadable org scopes folder stops setup and deletes nothing" {
  [ "$(id -u)" -eq 0 ] && skip "root reads a mode-000 folder"
  _org_overlay "gcloud"
  _overlay_setup_pass
  chmod 000 "$ORG/scopes"
  run phase_platform_discover_overlay
  chmod 755 "$ORG/scopes"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a readable directory"* ]]
  [ -f "$ENV_DIR/scopes/local_team.nix" ]
}

@test "overlay: a scope file name starting with local_ is skipped" {
  _org_overlay
  printf '{ pkgs }: with pkgs; [ hello ]\n' >"$ORG/scopes/local_extra.nix"
  run phase_platform_discover_overlay
  [[ "$output" == *"local_extra.nix ignored - scope file names cannot start with local_"* ]]
  [ ! -f "$ENV_DIR/scopes/local_local_extra.nix" ]
}

@test "overlay: the org overlay is remembered for shells without the variable" {
  _org_overlay "gcloud"
  _overlay_setup_pass
  [ "$(cat "$ENV_DIR/overlay_dir")" = "$ORG" ]
  unset NIX_ENV_OVERLAY_DIR
  _overlay_setup_pass
  [ "$OVERLAY_DIR" = "$ORG" ]
  read_config_scopes | grep -qx "local_team"
  read_config_scopes | grep -qx "gcloud"
}

@test "overlay: --overlay-dir sets and remembers the org overlay" {
  _org_overlay
  unset NIX_ENV_OVERLAY_DIR
  cd "$TEST_HOME"
  overlay_dir_arg="org-overlay"
  phase_platform_discover_overlay >/dev/null 2>&1
  [ "$OVERLAY_DIR" = "$ORG" ]
  [ "$(cat "$ENV_DIR/overlay_dir")" = "$ORG" ]
}

@test "overlay: a remembered org overlay that went missing stops setup" {
  _org_overlay
  _overlay_setup_pass
  unset NIX_ENV_OVERLAY_DIR
  mv "$ORG" "$ORG.away"
  run phase_platform_discover_overlay
  [ "$status" -eq 1 ]
  [[ "$output" == *"(from $ENV_DIR/overlay_dir) is not a readable directory"*"nx overlay unset"* ]]
}

@test "overlay: an org overlay path with a colon stops setup" {
  mkdir -p "$TEST_HOME/team:blue/scopes"
  export NIX_ENV_OVERLAY_DIR="$TEST_HOME/team:blue"
  run phase_platform_discover_overlay
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot contain ':'"* ]]
}

@test "overlay: hooks do not run from / when no overlay is active" {
  OVERLAY_DIR=""
  run phase_platform_run_overlay_hooks
  [ "$status" -eq 0 ]
  [[ "$output" != *"running overlay hook"* ]]
}

@test "overlay: a relative --overlay-dir resolves against where setup started" {
  NX_CALLER_PWD="$TEST_HOME/caller"
  phase_bootstrap_parse_args --overlay-dir team-overlay
  [ "$overlay_dir_arg" = "$TEST_HOME/caller/team-overlay" ]
  phase_bootstrap_parse_args --overlay-dir /abs/overlay
  [ "$overlay_dir_arg" = "/abs/overlay" ]
}

@test "overlay: --remove of a header scope's dependency is refused" {
  _org_overlay "az"
  _overlay_setup_pass
  read_config_scopes | grep -qx "python"
  OVERLAY_REMOVE=(python)
  run _overlay_setup_pass
  [[ "$output" == *"python is controlled by the organization overlay"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/run.log" ] || [ "$(grep -c python_remove.sh "$BATS_TEST_TMPDIR/run.log")" -eq 0 ]
}

@test "overlay: a first flagless run with an overlay skips system detection" {
  _org_overlay "shell"
  mkdir -p "$TEST_HOME/bin"
  printf '#!/bin/sh\nexit 0\n' >"$TEST_HOME/bin/docker"
  chmod +x "$TEST_HOME/bin/docker"
  PATH="$TEST_HOME/bin:$PATH" _overlay_setup_pass
  [ "$(read_config_scopes | grep -cx docker)" -eq 0 ]
  read_config_scopes | grep -qx "shell"
}

@test "overlay: an org overlay whose scopes entry is a file stops setup" {
  ORG="$TEST_HOME/org-overlay"
  mkdir -p "$ORG" && touch "$ORG/scopes"
  export NIX_ENV_OVERLAY_DIR="$ORG"
  run phase_platform_discover_overlay
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a readable directory"* ]]
}

@test "overlay: a dangling scopes symlink in the org overlay stops setup" {
  _org_overlay
  _overlay_setup_pass
  rm -r "$ORG/scopes"
  ln -s "$TEST_HOME/nowhere" "$ORG/scopes"
  run phase_platform_discover_overlay
  [ "$status" -eq 1 ]
  [ -f "$ENV_DIR/scopes/local_team.nix" ]
}

@test "overlay: a symlink to the config folder is refused as the org overlay" {
  ln -s "$ENV_DIR" "$TEST_HOME/alias"
  export NIX_ENV_OVERLAY_DIR="$TEST_HOME/alias"
  run phase_platform_discover_overlay
  [ "$status" -eq 1 ]
  [[ "$output" == *"is the Envy-NX config folder itself"* ]]
}

@test "overlay: an overlay prompt engine replaces the user's other engine without a flag" {
  _org_overlay "oh_my_posh"
  phase_platform_discover_overlay >/dev/null 2>&1
  _scope_set=" starship oh_my_posh "
  omp_theme="" starship_theme=""
  phase_scopes_enforce_prompt_exclusivity >/dev/null 2>&1
  scope_has oh_my_posh
  run scope_has starship
  [ "$status" -ne 0 ]
}

@test "overlay: the org prompt engine wins over a personal header's engine" {
  _org_overlay "oh_my_posh"
  mkdir -p "$ENV_DIR/local/scopes"
  printf '# scopes: starship\n{ pkgs }: with pkgs; []\n' >"$ENV_DIR/local/scopes/mine.nix"
  phase_platform_discover_overlay >/dev/null 2>&1
  _scope_set=" starship oh_my_posh local_team local_mine "
  omp_theme="" starship_theme=""
  phase_scopes_enforce_prompt_exclusivity >/dev/null 2>&1
  scope_has oh_my_posh
  run scope_has starship
  [ "$status" -ne 0 ]
}

@test "overlay: a theme flag for the org overlay's engine survives a personal header's other engine" {
  _org_overlay "oh_my_posh"
  mkdir -p "$ENV_DIR/local/scopes"
  printf '# scopes: starship\n{ pkgs }: with pkgs; []\n' >"$ENV_DIR/local/scopes/mine.nix"
  phase_platform_discover_overlay >/dev/null 2>&1
  _scope_set=" starship oh_my_posh local_team local_mine "
  omp_theme="nerd" starship_theme=""
  phase_scopes_enforce_prompt_exclusivity >/dev/null 2>&1
  [ "$omp_theme" = nerd ]
  scope_has oh_my_posh
  run scope_has starship
  [ "$status" -ne 0 ]
}

@test "overlay: two org headers naming both prompt engines keep one, with a warning" {
  _org_overlay "oh_my_posh"
  printf '# scopes: starship\n{ pkgs }: with pkgs; []\n' >"$ORG/scopes/prompt.nix"
  phase_platform_discover_overlay >/dev/null 2>&1
  _scope_set=" starship oh_my_posh "
  omp_theme="" starship_theme=""
  run phase_scopes_enforce_prompt_exclusivity
  [[ "$output" == *"overlays name both prompt engines"* ]]
  phase_scopes_enforce_prompt_exclusivity >/dev/null 2>&1
  scope_has oh_my_posh
  run scope_has starship
  [ "$status" -ne 0 ]
}

@test "overlay: the config folder itself is refused as the org overlay" {
  export NIX_ENV_OVERLAY_DIR="$ENV_DIR"
  run phase_platform_discover_overlay
  [ "$status" -eq 1 ]
  [[ "$output" == *"is the Envy-NX config folder itself"* ]]
  [ ! -f "$ENV_DIR/scopes/local_base.nix" ]
}

@test "overlay: a theme flag cannot displace an overlay's prompt engine" {
  _org_overlay "oh_my_posh"
  _overlay_setup_pass
  omp_theme="" starship_theme="base"
  _scope_set=" starship "
  _cli_scope_set="$_scope_set"
  any_scope=true
  remove_scopes=()
  phase_platform_discover_overlay >/dev/null 2>&1
  phase_scopes_load_existing >/dev/null 2>&1
  phase_scopes_apply_overlay
  run phase_scopes_enforce_prompt_exclusivity
  [[ "$output" == *"oh_my_posh is provided by an overlay"*"--starship-theme ignored"* ]]
  phase_scopes_enforce_prompt_exclusivity 2>/dev/null
  scope_has oh_my_posh
  [ -z "$starship_theme" ]
  run scope_has starship
  [ "$status" -ne 0 ]
}

@test "overlay: an empty saved org overlay path stops setup" {
  : >"$ENV_DIR/overlay_dir"
  run phase_platform_discover_overlay
  [ "$status" -eq 1 ]
  [[ "$output" == *"overlay_dir is empty"* ]]
}

@test "overlay: an org overlay with no scope files still skips system detection" {
  ORG="$TEST_HOME/org-overlay"
  mkdir -p "$ORG/shell_cfg" "$TEST_HOME/bin"
  export NIX_ENV_OVERLAY_DIR="$ORG"
  printf '#!/bin/sh\nexit 0\n' >"$TEST_HOME/bin/docker"
  chmod +x "$TEST_HOME/bin/docker"
  PATH="$TEST_HOME/bin:$PATH" _overlay_setup_pass
  [ "$(read_config_scopes | grep -cx docker)" -eq 0 ]
}

@test "overlay: a flag for an org-provided scope says so" {
  _org_overlay "gcloud"
  run _overlay_setup_pass gcloud
  [[ "$output" == *"gcloud is provided by the organization overlay"* ]]
}

@test "overlay: post-setup hooks run as child processes, failures only warn" {
  _org_overlay
  mkdir -p "$ORG/hooks/post-setup.d" "$ENV_DIR/local/hooks/post-setup.d"
  printf 'echo "org hook ENV_DIR=$ENV_DIR"\nexit 3\n' >"$ORG/hooks/post-setup.d/10-org.sh"
  printf 'echo "personal hook"; hook_var=set\n' >"$ENV_DIR/local/hooks/post-setup.d/10-mine.sh"
  phase_platform_discover_overlay >/dev/null 2>&1
  run phase_platform_run_overlay_hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"org hook ENV_DIR=$ENV_DIR"*"overlay hook failed: $ORG/hooks/post-setup.d/10-org.sh"*"personal hook"* ]]
  phase_platform_run_overlay_hooks >/dev/null 2>&1
  [ -z "${hook_var:-}" ]
}

@test "overlay: a hook reading stdin does not skip the next overlay's hooks" {
  _org_overlay
  mkdir -p "$ORG/hooks/post-setup.d" "$ENV_DIR/local/hooks/post-setup.d"
  printf 'cat >/dev/null\n' >"$ORG/hooks/post-setup.d/10-org.sh"
  printf 'echo "personal hook"\n' >"$ENV_DIR/local/hooks/post-setup.d/10-mine.sh"
  phase_platform_discover_overlay >/dev/null 2>&1
  run phase_platform_run_overlay_hooks </dev/null
  [[ "$output" == *"personal hook"* ]]
}

# =============================================================================
# phase_bootstrap_print_banner
# =============================================================================

@test "banner: prints SCRIPT_ROOT, branch, and NIX_ENV_VERSION when in a git repo" {
  # Create a throwaway git repo with a known branch + tag so the banner has
  # deterministic output. Mirrors what `git describe --tags --dirty` reports
  # at the start of nix/setup.sh.
  local _repo="$BATS_TEST_TMPDIR/banner-repo"
  mkdir -p "$_repo"
  git -C "$_repo" init -q -b main
  git -C "$_repo" config user.email t@t
  git -C "$_repo" config user.name t
  : >"$_repo/file"
  git -C "$_repo" add file
  git -C "$_repo" commit -qm initial
  git -C "$_repo" tag v1.0.0
  git -C "$_repo" checkout -qb feat/banner-test

  SCRIPT_ROOT="$_repo"
  NIX_ENV_VERSION="$(git -C "$_repo" describe --tags --dirty)"
  run phase_bootstrap_print_banner
  [ "$status" -eq 0 ]
  [[ "$output" == *"Running setup from $_repo"* ]]
  [[ "$output" == *"feat/banner-test"* ]]
  [[ "$output" == *"v1.0.0"* ]]
}

@test "banner: omits branch parens content but still prints version when not a git repo" {
  # Tarball-install case: SCRIPT_ROOT exists but isn't a git work tree.
  # rev-parse --abbrev-ref returns empty -> the banner prints
  # `Running setup from <path> ([<version>])`.
  local _dir="$BATS_TEST_TMPDIR/no-git"
  mkdir -p "$_dir"
  SCRIPT_ROOT="$_dir"
  NIX_ENV_VERSION="1.6.0-tarball"
  run phase_bootstrap_print_banner
  [ "$status" -eq 0 ]
  [[ "$output" == *"Running setup from $_dir"* ]]
  [[ "$output" == *"1.6.0-tarball"* ]]
  # No branch token should appear inside the parens.
  [[ "$output" != *"(\e[3;90m"*"-"* ]] || true
}
