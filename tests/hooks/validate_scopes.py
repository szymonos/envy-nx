"""
Validate internal consistency of scope definitions.

Checks:
- valid_scopes and install_order contain the same scopes (scopes.json)
- all dependency rule triggers and targets exist in valid_scopes
- every scope in valid_scopes has a matching .nix file
- every scope .nix file has a '# bins:' comment
- every scope is reachable from nix/setup.sh's CLI, and every scope flag it
  offers names a real scope (case arm, NX_SETUP_FLAGS, --help text)

# :example
python3 -m tests.hooks.validate_scopes
"""

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCOPES_JSON = REPO_ROOT / ".assets" / "lib" / "scopes.json"
SCOPES_DIR = REPO_ROOT / "nix" / "scopes"
CONFIGURE_DIR = REPO_ROOT / "nix" / "configure"
BOOTSTRAP_SH = REPO_ROOT / "nix" / "lib" / "phases" / "bootstrap.sh"

BINS_RE = re.compile(r"^# bins:\s+\S", re.MULTILINE)
PARSE_ARGS_RE = re.compile(
    r"^phase_bootstrap_parse_args\(\) \{(.*?)^\}$", re.DOTALL | re.MULTILINE
)
ALL_ARM_RE = re.compile(r"--all\)(.*?);;", re.DOTALL)
FLAGS_ARRAY_RE = re.compile(r"^NX_SETUP_FLAGS=\((.*?)^\)$", re.DOTALL | re.MULTILINE)
USAGE_SCOPES_RE = re.compile(r"^Scope flags.*?^  --all\b", re.DOTALL | re.MULTILINE)
FLAG_RE = re.compile(r"--[a-z0-9-]+")
EMPTY_SCOPE_RE = re.compile(r"^\{[^}]*\}:\s*\[\s*\]$")


def _scope_flag(scope: str) -> str:
    """CLI spelling of a scope name: k8s_base -> --k8s-base."""
    return "--" + scope.replace("_", "-")


def _inert_in_nix_path(scope: str) -> bool:
    """
    True when a scope neither installs packages nor has a configure script.

    conda and gcloud have empty package lists too, but each has a
    nix/configure/<scope>.sh that does the real work, so both are requestable.
    """
    nix_file = SCOPES_DIR / f"{scope}.nix"
    if not nix_file.exists():
        return False
    body = "\n".join(
        ln
        for ln in nix_file.read_text().splitlines()
        if not ln.lstrip().startswith("#")
    ).strip()
    if not EMPTY_SCOPE_RE.match(body):
        return False
    return not (CONFIGURE_DIR / f"{scope}.sh").exists()


def _cli_surfaces(text: str) -> tuple[set[str], set[str], set[str], set[str]]:
    """Extract (scope case arm, --all skips, NX_SETUP_FLAGS, --help) flag sets."""
    body_match = PARSE_ARGS_RE.search(text)
    body = body_match.group(1) if body_match else ""

    # The scope arm is the one whose body calls scope_add on the flag itself.
    # Found by walking back from that call to the end of the previous arm,
    # which survives however the alternation is wrapped across lines.
    case_flags: set[str] = set()
    marker = 'scope_add "${1#--}"'
    if marker in body:
        idx = body.index(marker)
        start = max(body.rfind(";;", 0, idx), body.rfind(" in\n", 0, idx))
        case_flags = set(FLAG_RE.findall(body[start:idx]))

    all_arm = ALL_ARM_RE.search(body)
    skipped = (
        {
            _scope_flag(s)
            for s in re.findall(r'"\$s" == "([a-z0-9_]+)"', all_arm.group(1))
        }
        if all_arm
        else set()
    )

    array = FLAGS_ARRAY_RE.search(text)
    declared = set(FLAG_RE.findall(array.group(1))) if array else set()

    usage = USAGE_SCOPES_RE.search(text)
    documented = set(FLAG_RE.findall(usage.group(0))) - {"--all"} if usage else set()

    return case_flags, skipped, declared, documented


def _check_cli_surface(valid: set[str], errors: list[str]) -> None:
    """Cross-check scopes.json against nix/setup.sh's three CLI surfaces."""
    if not BOOTSTRAP_SH.exists():
        errors.append(f"{BOOTSTRAP_SH.name} not found")
        return
    text = BOOTSTRAP_SH.read_text()
    case_flags, skipped, declared, documented = _cli_surfaces(text)

    if not case_flags:
        errors.append("could not locate the scope arm in phase_bootstrap_parse_args")
        return

    # Two kinds of scope have no --<scope> flag on purpose, and both exceptions
    # are read out of the code that creates them rather than named here:
    #   - prompt scopes, reachable only via --omp-theme / --starship-theme,
    #     which scope_add them internally (taken from the --all arm that skips
    #     them, so a third prompt scope needs no edit in this hook);
    #   - scopes that do nothing in the nix path at all: no packages and no
    #     nix/configure/<scope>.sh. distrobox is the only one - it is a root
    #     install left to the user, and keeps a .nix file solely to satisfy the
    #     one-file-per-scope rule above. Give it either and a flag is required.
    inert = {_scope_flag(s) for s in valid if _inert_in_nix_path(s)}
    expected = {_scope_flag(s) for s in valid} - skipped - inert

    for label, actual in (
        ("the parse_args scope arm", case_flags),
        ("--help", documented),
    ):
        for flag in sorted(expected - actual):
            errors.append(f"scope flag '{flag}' missing from {label}")
        for flag in sorted(actual - expected):
            errors.append(f"{label} offers '{flag}', which is not a valid scope")

    # NX_SETUP_FLAGS gates every flag before parse_args ever runs, so a scope
    # flag absent here is rejected as an unknown option and unreachable. Only
    # this direction is checked, unlike the two surfaces above: the array also
    # carries every non-scope option (--upgrade, --remove, -h ...), so
    # "declared but not a scope" would flag all of them, and excluding them
    # would mean maintaining a third list. The other direction is covered by
    # test_setup_args.bats, which asserts the array and the case statement
    # hold the same set.
    for flag in sorted(expected - declared):
        errors.append(f"scope flag '{flag}' missing from NX_SETUP_FLAGS")


def validate() -> int:  # noqa: C901 -- structural: many independent consistency checks
    """Cross-check scopes.json against scope .nix files; return 1 on errors."""
    if not SCOPES_JSON.exists():
        print(f"ERROR: {SCOPES_JSON} not found", file=sys.stderr)
        return 1

    data = json.loads(SCOPES_JSON.read_text())
    errors: list[str] = []

    valid = set(data["valid_scopes"])
    order = set(data["install_order"])

    # valid_scopes and install_order must contain the same scopes
    if valid != order:
        only_valid = sorted(valid - order)
        only_order = sorted(order - valid)
        msg = "valid_scopes and install_order differ"
        if only_valid:
            msg += f"\n  in valid_scopes only: {' '.join(only_valid)}"
        if only_order:
            msg += f"\n  in install_order only: {' '.join(only_order)}"
        errors.append(msg)

    # check for duplicates
    if len(data["valid_scopes"]) != len(valid):
        errors.append("valid_scopes contains duplicates")
    if len(data["install_order"]) != len(order):
        errors.append("install_order contains duplicates")

    # dependency rules: all triggers and targets must be valid scopes
    for rule in data["dependency_rules"]:
        trigger = rule["if"]
        if trigger not in valid:
            errors.append(f"dependency rule trigger '{trigger}' not in valid_scopes")
        for target in rule["add"]:
            if target not in valid:
                errors.append(
                    f"dependency rule target '{target}' (from '{trigger}') "
                    "not in valid_scopes"
                )

    # every scope must have a .nix file with a '# bins:' comment
    for scope in sorted(valid):
        nix_file = SCOPES_DIR / f"{scope}.nix"
        if not nix_file.exists():
            errors.append(f"scope '{scope}' has no matching {nix_file.name}")
            continue
        content = nix_file.read_text()
        if not BINS_RE.search(content):
            errors.append(f"{nix_file.name} missing '# bins:' comment")

    _check_cli_surface(valid, errors)

    if errors:
        print("Scope definition errors:", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(validate())
