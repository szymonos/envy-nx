#!/usr/bin/env bats
# Unit tests for tests/hooks/validate_scopes.py - the hook that keeps
# scopes.json, nix/scopes/*.nix and nix/setup.sh's three CLI surfaces
# (parse_args case arm, NX_SETUP_FLAGS, --help) in agreement.
#
# Every test builds a complete miniature repo under $FIXTURE and points the
# hook's module-level paths at it, so a case can be made to fail by changing
# exactly one surface.
# shellcheck disable=SC2154
bats_require_minimum_version 1.5.0

REPO_SRC="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  FIXTURE="$(mktemp -d)"
  mkdir -p "$FIXTURE/scopes" "$FIXTURE/configure"
  cd "$REPO_SRC" || return 1
  _write_valid_fixture
}

teardown() {
  rm -rf "$FIXTURE"
}

# ---------------------------------------------------------------------------
# fixture builders
# ---------------------------------------------------------------------------

# alpha/beta  - ordinary scopes, each needs a --flag on all three surfaces
# oh_my_posh  - prompt scope, reachable only via --omp-theme; the --all arm
#               skips it, which is how the hook derives the exception
# inert       - no packages and no configure script, so it needs no flag
#               (this is `distrobox` in the real repo)
_write_scopes_json() {
  cat >"$FIXTURE/scopes.json" <<'JSON'
{
  "valid_scopes": ["alpha", "beta", "oh_my_posh", "inert"],
  "install_order": ["alpha", "beta", "oh_my_posh", "inert"],
  "dependency_rules": [{"if": "beta", "add": ["alpha"]}]
}
JSON
}

_write_nix_files() {
  printf '# bins: alpha\n{ pkgs }: [ pkgs.alpha ]\n' >"$FIXTURE/scopes/alpha.nix"
  printf '# bins: beta\n{ pkgs }: [ pkgs.beta ]\n' >"$FIXTURE/scopes/beta.nix"
  printf '# bins: omp\n{ pkgs }: [ pkgs.omp ]\n' >"$FIXTURE/scopes/oh_my_posh.nix"
  # no packages AND (below) no configure script => inert in the nix path
  printf '# bins:  none\n{ pkgs }: [ ]\n' >"$FIXTURE/scopes/inert.nix"
}

# $1 case-arm flags, $2 NX_SETUP_FLAGS scope flags, $3 --help scope flags
_write_bootstrap() {
  local case_flags="${1:---alpha | --beta}"
  local array_flags="${2:---alpha --beta}"
  local help_flags="${3:-  --alpha       Alpha\n  --beta        Beta}"
  cat >"$FIXTURE/bootstrap.sh" <<EOF
#!/usr/bin/env bash
phase_bootstrap_parse_args() {
  while [ \$# -gt 0 ]; do
    case "\$1" in
    -h | --help)
      usage
      ;;
    $case_flags)
      scope_add "\${1#--}"
      any_scope=true
      ;;
    --all)
      for s in "\${VALID_SCOPES[@]}"; do
        [[ "\$s" == "oh_my_posh" ]] && continue
        scope_add "\$s"
      done
      any_scope=true
      ;;
    esac
    shift
  done
}

NX_SETUP_FLAGS=(
  -h --help
  $array_flags
  --all --omp-theme --remove --upgrade
)

usage() {
  cat <<'USAGE'
Scope flags (add new packages - merged with existing config):
$(printf "$help_flags")
  --all         Everything
USAGE
}
EOF
}

_write_valid_fixture() {
  _write_scopes_json
  _write_nix_files
  _write_bootstrap
}

# Run validate() with the hook's module-level paths redirected at $FIXTURE.
_run_hook() {
  python3 - "$FIXTURE" <<'PY'
import pathlib
import sys

from tests.hooks import validate_scopes as vs

root = pathlib.Path(sys.argv[1])
vs.SCOPES_JSON = root / "scopes.json"
vs.SCOPES_DIR = root / "scopes"
vs.CONFIGURE_DIR = root / "configure"
vs.BOOTSTRAP_SH = root / "bootstrap.sh"
sys.exit(vs.validate())
PY
}

# ---------------------------------------------------------------------------
# baseline
# ---------------------------------------------------------------------------

@test "a fixture with all surfaces in agreement passes" {
  run _run_hook
  [ "$status" -eq 0 ]
}

@test "the real repo passes its own hook" {
  run python3 -m tests.hooks.validate_scopes
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# CLI surface cross-check - one surface dropped at a time
# ---------------------------------------------------------------------------

@test "scope missing from the parse_args case arm is reported" {
  _write_bootstrap "--alpha"
  run _run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"'--beta' missing from the parse_args scope arm"* ]]
}

@test "scope missing from NX_SETUP_FLAGS is reported" {
  # Unreachable in practice: the array gates every flag before parse_args
  # runs, so the scope is rejected as an unknown option.
  _write_bootstrap "--alpha | --beta" "--alpha"
  run _run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"'--beta' missing from NX_SETUP_FLAGS"* ]]
}

@test "scope missing from --help is reported" {
  _write_bootstrap "--alpha | --beta" "--alpha --beta" "  --alpha       Alpha"
  run _run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"'--beta' missing from --help"* ]]
}

@test "a flag naming no real scope is reported" {
  _write_bootstrap "--alpha | --beta | --ghost" "--alpha --beta --ghost" \
    "  --alpha       Alpha\n  --beta        Beta\n  --ghost       Ghost"
  run _run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"offers '--ghost', which is not a valid scope"* ]]
}

@test "hook fails when the scope arm cannot be located at all" {
  printf '#!/usr/bin/env bash\n# no parse_args here\n' >"$FIXTURE/bootstrap.sh"
  run _run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not locate the scope arm"* ]]
}

@test "missing bootstrap.sh is reported rather than crashing" {
  rm -f "$FIXTURE/bootstrap.sh"
  run _run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"bootstrap.sh not found"* ]]
}

# ---------------------------------------------------------------------------
# the two deliberate flag exceptions, both derived from code not hardcoded
# ---------------------------------------------------------------------------

@test "a prompt scope skipped by the --all arm needs no flag of its own" {
  # oh_my_posh is in valid_scopes but on no CLI surface, and the fixture still
  # passes - the exception comes from the --all arm's skip list.
  run _run_hook
  [ "$status" -eq 0 ]
  run grep -c 'oh-my-posh' "$FIXTURE/bootstrap.sh"
  [ "$output" -eq 0 ]
}

@test "a third prompt scope needs no hook edit, only an --all skip" {
  printf '# bins: sshp\n{ pkgs }: [ pkgs.starship ]\n' >"$FIXTURE/scopes/starship.nix"
  sed 's/"inert"\]/"inert", "starship"]/g' "$FIXTURE/scopes.json" >"$FIXTURE/tmp.json"
  command mv -f "$FIXTURE/tmp.json" "$FIXTURE/scopes.json"
  sed 's/== "oh_my_posh" \]\]/== "oh_my_posh" || "$s" == "starship" ]]/' \
    "$FIXTURE/bootstrap.sh" >"$FIXTURE/tmp.sh"
  command mv -f "$FIXTURE/tmp.sh" "$FIXTURE/bootstrap.sh"
  run _run_hook
  [ "$status" -eq 0 ]
}

@test "a scope inert in the nix path needs no flag" {
  # 'inert' has an empty package list and no configure script.
  run _run_hook
  [ "$status" -eq 0 ]
}

@test "an inert scope that gains a configure script now requires a flag" {
  # This is the guard that keeps the distrobox exception from silently
  # covering a scope that started doing real work.
  printf '#!/usr/bin/env bash\n' >"$FIXTURE/configure/inert.sh"
  run _run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"'--inert' missing from the parse_args scope arm"* ]]
}

@test "an inert scope that gains packages now requires a flag" {
  printf '# bins: thing\n{ pkgs }: [ pkgs.thing ]\n' >"$FIXTURE/scopes/inert.nix"
  run _run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"'--inert' missing from the parse_args scope arm"* ]]
}

@test "underscores in a scope name become dashes in its flag" {
  printf '# bins: kb\n{ pkgs }: [ pkgs.kb ]\n' >"$FIXTURE/scopes/k8s_base.nix"
  sed 's/"inert"\]/"inert", "k8s_base"]/g' "$FIXTURE/scopes.json" >"$FIXTURE/tmp.json"
  command mv -f "$FIXTURE/tmp.json" "$FIXTURE/scopes.json"
  run _run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"'--k8s-base' missing"* ]]
}

# ---------------------------------------------------------------------------
# scopes.json internal consistency
# ---------------------------------------------------------------------------

@test "valid_scopes and install_order holding different sets is reported" {
  cat >"$FIXTURE/scopes.json" <<'JSON'
{
  "valid_scopes": ["alpha", "beta", "oh_my_posh", "inert"],
  "install_order": ["alpha", "oh_my_posh", "inert"],
  "dependency_rules": []
}
JSON
  run _run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"valid_scopes and install_order differ"* ]]
  [[ "$output" == *"in valid_scopes only: beta"* ]]
}

@test "a duplicate in valid_scopes is reported" {
  cat >"$FIXTURE/scopes.json" <<'JSON'
{
  "valid_scopes": ["alpha", "alpha", "beta", "oh_my_posh", "inert"],
  "install_order": ["alpha", "beta", "oh_my_posh", "inert"],
  "dependency_rules": []
}
JSON
  run _run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"valid_scopes contains duplicates"* ]]
}

@test "a dependency rule naming an unknown trigger is reported" {
  cat >"$FIXTURE/scopes.json" <<'JSON'
{
  "valid_scopes": ["alpha", "beta", "oh_my_posh", "inert"],
  "install_order": ["alpha", "beta", "oh_my_posh", "inert"],
  "dependency_rules": [{"if": "nope", "add": ["alpha"]}]
}
JSON
  run _run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"trigger 'nope' not in valid_scopes"* ]]
}

@test "a dependency rule naming an unknown target is reported" {
  cat >"$FIXTURE/scopes.json" <<'JSON'
{
  "valid_scopes": ["alpha", "beta", "oh_my_posh", "inert"],
  "install_order": ["alpha", "beta", "oh_my_posh", "inert"],
  "dependency_rules": [{"if": "beta", "add": ["nope"]}]
}
JSON
  run _run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"target 'nope' (from 'beta') not in valid_scopes"* ]]
}

# ---------------------------------------------------------------------------
# scope .nix files
# ---------------------------------------------------------------------------

@test "a scope with no .nix file is reported" {
  rm -f "$FIXTURE/scopes/beta.nix"
  run _run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"scope 'beta' has no matching beta.nix"* ]]
}

@test "a .nix file without a '# bins:' comment is reported" {
  printf '{ pkgs }: [ pkgs.beta ]\n' >"$FIXTURE/scopes/beta.nix"
  run _run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"beta.nix missing '# bins:' comment"* ]]
}

@test "a '# bins:' comment with no binaries listed is reported" {
  printf '# bins:\n{ pkgs }: [ pkgs.beta ]\n' >"$FIXTURE/scopes/beta.nix"
  run _run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"beta.nix missing '# bins:' comment"* ]]
}

@test "a missing scopes.json is reported rather than crashing" {
  rm -f "$FIXTURE/scopes.json"
  run _run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}
