"""
Verify the nx lib-file list is consistent across all three places that
install or audit `~/.config/nix-env/`:

  1. `phase_bootstrap_sync_env_dir` (nix/lib/phases/bootstrap.sh)
     - `install_atomic` copy loop, run on every `nix/setup.sh`.
  2. `_nx_self_sync` (.assets/lib/nx_lifecycle.sh)
     - `cp` loop, run by `nx self update` to refresh the durable env.
  3. `_check_env_dir_files` (.assets/lib/nx_doctor.sh)
     - Existence check, run by `nx doctor`. Adds `flake.nix` and
       `config.nix` as auxiliaries (they live in ENV_DIR but aren't
       sourced from .assets/lib/).

Adding a new family file (or renaming one) requires touching all three.
This hook fails when the lists drift - same shape as
`check-nx-completions`, `check-nx-profile-parity`, and
`check-nx-dispatch-parity`.

# :example
python3 -m tests.hooks.check_nx_lib_files_parity
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BOOTSTRAP = REPO_ROOT / "nix/lib/phases/bootstrap.sh"
LIFECYCLE = REPO_ROOT / ".assets/lib/nx_lifecycle.sh"
DOCTOR = REPO_ROOT / ".assets/lib/nx_doctor.sh"

# Files in nx_doctor.sh's check that are not from .assets/lib/ but are
# legitimately expected in ENV_DIR (produced by other phases). Subtracted
# before comparison.
DOCTOR_AUXILIARIES = {"flake.nix", "config.nix"}

LOCATIONS = [
    (
        BOOTSTRAP,
        re.compile(r"for\s+_nx_lib\s+in\s+([^;]+);\s*do"),
        "phase_bootstrap_sync_env_dir (install_atomic loop)",
    ),
    (
        LIFECYCLE,
        re.compile(r"for\s+f\s+in\s+([^;]+);\s*do"),
        "_nx_self_sync (cp loop)",
    ),
    (
        DOCTOR,
        re.compile(r"for\s+_f\s+in\s+([^;]+);\s*do"),
        "_check_env_dir_files (existence check)",
    ),
]


def _extract(path: Path, regex: re.Pattern) -> set[str]:
    text = path.read_text()
    m = regex.search(text)
    if not m:
        raise SystemExit(
            f"could not find file list (pattern {regex.pattern!r}) "
            f"in {path.relative_to(REPO_ROOT)}"
        )
    return set(m.group(1).split())


def main() -> None:
    extracted: dict[Path, set[str]] = {}
    for path, regex, _label in LOCATIONS:
        files = _extract(path, regex)
        if path == DOCTOR:
            files = files - DOCTOR_AUXILIARIES
        extracted[path] = files

    sets = list(extracted.values())
    if all(s == sets[0] for s in sets):
        return

    print(
        "nx lib-file lists are out of sync across install/audit locations:",
        file=sys.stderr,
    )
    for path, _regex, label in LOCATIONS:
        files = extracted[path]
        print(
            f"  {path.relative_to(REPO_ROOT)} ({label}):\n"
            f"    {', '.join(sorted(files)) if files else '(empty)'}",
            file=sys.stderr,
        )
    print(
        "\nKeep all three in sync. nx_doctor.sh's list legitimately adds "
        f"{', '.join(sorted(DOCTOR_AUXILIARIES))} as auxiliaries; everything "
        "else must match.",
        file=sys.stderr,
    )
    sys.exit(1)


if __name__ == "__main__":
    main()
