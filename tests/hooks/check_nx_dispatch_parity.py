"""
Verify the bash `nx_main` dispatcher in `.assets/lib/nx.sh` exposes the
same verb surface as `.assets/lib/nx_surface.json`.

The manifest is the authoritative source for what verbs (and aliases)
the user can type. Drift produces user-visible bugs:
  - manifest declares a verb the dispatcher doesn't case → completer
    suggests it, tab-pressing gives "Unknown command".
  - dispatcher accepts an alias the manifest doesn't declare → user can
    type it, but completer never suggests it and `nx help` never lists
    it.

Companion to `check-nx-completions` (completer drift) and
`check-nx-profile-parity` (PS profile-subverb drift) - this closes the
remaining drift loop on the bash side.

# :example
python3 -m tests.hooks.check_nx_dispatch_parity
"""

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST = REPO_ROOT / ".assets/lib/nx_surface.json"
NX_FILE = REPO_ROOT / ".assets/lib/nx.sh"

# Anchor on `function nx_main() { ... case "$cmd" in ... esac ... }`
NX_CASE_RE = re.compile(
    r"function\s+nx_main\s*\(\)\s*\{.*?case\s+\"\$cmd\"\s+in(.*?)\s+esac",
    re.DOTALL,
)
# Each case arm: optional leading whitespace, then `pat1 | pat2 | ...) ...`.
# Match patterns that look like word/alias tokens (letters, digits, _, -).
# Skip the `*)` catch-all by requiring at least one identifier char.
CASE_ARM_RE = re.compile(r"^\s*([a-zA-Z][a-zA-Z0-9_|\s\-]*)\)", re.MULTILINE)


def _manifest_tokens() -> set[str]:
    manifest = json.loads(MANIFEST.read_text())
    tokens: set[str] = set()
    for verb in manifest["verbs"]:
        tokens.add(verb["name"])
        tokens.update(verb.get("aliases", []))
    return tokens


def _dispatch_tokens() -> set[str]:
    text = NX_FILE.read_text()
    block = NX_CASE_RE.search(text)
    if not block:
        raise SystemExit(
            f'`function nx_main () {{ ... case "$cmd" in ... esac }}` '
            f"not found in {NX_FILE.relative_to(REPO_ROOT)}"
        )
    tokens: set[str] = set()
    for arm in CASE_ARM_RE.findall(block.group(1)):
        for pat in arm.split("|"):
            pat = pat.strip()
            if pat:
                tokens.add(pat)
    return tokens


def main() -> None:
    expected = _manifest_tokens()
    actual = _dispatch_tokens()
    missing = expected - actual
    extra = actual - expected
    if not (missing or extra):
        return
    print(
        f"nx_main dispatcher in {NX_FILE.relative_to(REPO_ROOT)} is out of "
        "sync with .assets/lib/nx_surface.json:",
        file=sys.stderr,
    )
    if missing:
        print(
            f"  declared in manifest, missing in dispatcher: "
            f"{', '.join(sorted(missing))}",
            file=sys.stderr,
        )
    if extra:
        print(
            f"  accepted by dispatcher, undeclared in manifest: "
            f"{', '.join(sorted(extra))}",
            file=sys.stderr,
        )
    print(
        "\nFix one side: add/remove the case arm in nx.sh, or add/remove "
        "the verb (or its `aliases`) in nx_surface.json.",
        file=sys.stderr,
    )
    sys.exit(1)


if __name__ == "__main__":
    main()
