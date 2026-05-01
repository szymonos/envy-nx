"""
Verify the committed nx tab completers and `nx help` text match what
gen_nx_completions would emit from .assets/lib/nx_surface.json.

Catches drift in either direction:
  - manifest changed but completers/help not regenerated
  - completer file or `_nx_lifecycle_help` body hand-edited bypassing
    the manifest

# :example
python3 -m tests.hooks.check_nx_completions
"""

import json
import sys

from tests.hooks import gen_nx_completions as gen


def main():
    manifest = json.loads(gen.MANIFEST.read_text())
    expected_bash = gen.emit_bash(manifest)
    expected_zsh = gen.emit_zsh(manifest)
    expected_ps_region = gen.emit_ps_region(manifest)
    expected_help = gen.emit_lifecycle_help(manifest)

    failures = []

    if gen.BASH_OUT.read_text() != expected_bash:
        failures.append(str(gen.BASH_OUT.relative_to(gen.REPO_ROOT)))

    if gen.ZSH_OUT.read_text() != expected_zsh:
        failures.append(str(gen.ZSH_OUT.relative_to(gen.REPO_ROOT)))

    ps_text = gen.PS_FILE.read_text()
    region_match = gen.PS_REGION_RE.search(ps_text)
    if not region_match:
        failures.append(
            f"{gen.PS_FILE.relative_to(gen.REPO_ROOT)} (missing #region nx-completer markers)"
        )
    elif region_match.group(0) != expected_ps_region:
        failures.append(
            f"{gen.PS_FILE.relative_to(gen.REPO_ROOT)} (nx-completer region)"
        )

    lifecycle_text = gen.LIFECYCLE_FILE.read_text()
    help_match = gen.HELP_REGION_RE.search(lifecycle_text)
    if not help_match:
        failures.append(
            f"{gen.LIFECYCLE_FILE.relative_to(gen.REPO_ROOT)} (missing nx-help markers)"
        )
    elif help_match.group(0) != expected_help:
        failures.append(
            f"{gen.LIFECYCLE_FILE.relative_to(gen.REPO_ROOT)} (nx-help region)"
        )

    if failures:
        print(
            "nx generated outputs are out of sync with .assets/lib/nx_surface.json:",
            file=sys.stderr,
        )
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        print(
            "\nRegenerate with: python3 -m tests.hooks.gen_nx_completions",
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
