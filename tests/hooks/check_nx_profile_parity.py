"""
Verify the bash and PowerShell `nx profile` dispatchers expose the same
subverb surface.

The two dispatchers are intentionally separate implementations - they
operate on structurally different files (bash/zsh rc with `# >>> nix-env
managed >>>` blocks vs PowerShell `$PROFILE` with `#region nix:* ...
#endregion` regions) and cannot share logic. But the user-facing surface
(`nx profile <subverb>`) must stay in sync so a user who switches shells
gets the same verb set.

Source of truth: `.assets/lib/nx_surface.json` (the manifest already
declares the bash side via the completion generator). This hook asserts
the PS dispatcher in `_aliases_nix.ps1` covers exactly the same subverbs.

# :example
python3 -m tests.hooks.check_nx_profile_parity
"""

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST = REPO_ROOT / ".assets/lib/nx_surface.json"
PS_FILE = REPO_ROOT / ".assets/config/pwsh_cfg/_aliases_nix.ps1"

# Anchor on `switch ($subCmd) { ... }` - unique to the nx profile dispatcher
PS_SWITCH_RE = re.compile(
    r"switch\s*\(\$subCmd\)\s*\{(.*?)\n\s*\}\s*\n\s*return",
    re.DOTALL,
)
PS_CASE_RE = re.compile(r"^\s*'([^']+)'\s*\{", re.MULTILINE)


def _manifest_profile_subverbs() -> set[str]:
    manifest = json.loads(MANIFEST.read_text())
    verb = next((v for v in manifest["verbs"] if v["name"] == "profile"), None)
    if verb is None:
        raise SystemExit("nx_surface.json: 'profile' verb not found")
    names: set[str] = set()
    for sv in verb.get("subverbs", []):
        names.add(sv["name"])
        names.update(sv.get("aliases", []))
    return names


def _ps_profile_subverbs() -> set[str]:
    text = PS_FILE.read_text()
    block = PS_SWITCH_RE.search(text)
    if not block:
        raise SystemExit(
            f"`switch ($subCmd) {{ ... }} return` not found in "
            f"{PS_FILE.relative_to(REPO_ROOT)}"
        )
    cases = set(PS_CASE_RE.findall(block.group(1)))
    cases.discard("default")
    return cases


def main() -> None:
    expected = _manifest_profile_subverbs()
    actual = _ps_profile_subverbs()
    missing = expected - actual
    extra = actual - expected
    if not (missing or extra):
        return
    print(
        "nx profile dispatcher in _aliases_nix.ps1 is out of sync with "
        "nx_surface.json:",
        file=sys.stderr,
    )
    if missing:
        print(
            f"  missing in PS dispatcher: {', '.join(sorted(missing))}", file=sys.stderr
        )
    if extra:
        print(
            f"  extra in PS dispatcher:   {', '.join(sorted(extra))}", file=sys.stderr
        )
    print(
        "\nUpdate .assets/config/pwsh_cfg/_aliases_nix.ps1's "
        "`switch ($subCmd)` block to match.",
        file=sys.stderr,
    )
    sys.exit(1)


if __name__ == "__main__":
    main()
