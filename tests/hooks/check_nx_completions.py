"""
Verify every artifact `gen_nx_completions` produces matches what's
committed - completers, `nx help`, `nx_main` dispatcher, PS profile
dispatch, and the lib-file lists across bootstrap/lifecycle/doctor.

Catches drift in either direction:
  - manifest changed but artifacts not regenerated
  - generated content hand-edited bypassing the manifest

This single check supersedes the three retired hooks:
  check-nx-dispatch-parity, check-nx-profile-parity,
  check-nx-lib-files-parity. Generation is strictly more powerful than
  parsing-and-diffing - the same correctness guarantee with one mental
  model and ~600 fewer lines of regex.

# :example
python3 -m tests.hooks.check_nx_completions
"""

import json
import sys

from tests.hooks import gen_nx_completions as gen


def _check_full_file(path, expected, failures):
    if path.read_text() != expected:
        failures.append(str(path.relative_to(gen.REPO_ROOT)))


def _check_region(path, region_re, expected, label, failures):
    text = path.read_text()
    m = region_re.search(text)
    rel = path.relative_to(gen.REPO_ROOT)
    if not m:
        failures.append(f"{rel} (missing {label} markers)")
    elif m.group(0) != expected:
        failures.append(f"{rel} ({label})")


def main():
    manifest = json.loads(gen.MANIFEST.read_text())
    failures = []

    _check_full_file(gen.BASH_OUT, gen.emit_bash(manifest), failures)
    _check_full_file(gen.ZSH_OUT, gen.emit_zsh(manifest), failures)
    _check_region(
        gen.PS_FILE,
        gen.PS_REGION_RE,
        gen.emit_ps_region(manifest),
        "nx-completer region",
        failures,
    )
    _check_region(
        gen.LIFECYCLE_FILE,
        gen.HELP_REGION_RE,
        gen.emit_lifecycle_help(manifest),
        "nx-help region",
        failures,
    )
    _check_region(
        gen.NX_FILE,
        gen.NX_MAIN_REGION_RE,
        gen.emit_nx_main(manifest),
        "nx-main region",
        failures,
    )
    _check_region(
        gen.PS_FILE,
        gen.PS_DISPATCH_REGION_RE,
        gen.emit_ps_profile_dispatch(manifest),
        "nx:dispatch region",
        failures,
    )
    _check_region(
        gen.BOOTSTRAP_FILE,
        gen.LIB_FILES_REGION_RE,
        gen.emit_lib_files_region(manifest, "_nx_lib"),
        "nx-libs region (bootstrap)",
        failures,
    )
    # Note: nx_lifecycle.sh's lib-files for-loop was retired - `_nx_self_sync`
    # delegates to `nix/setup.sh --skip-repo-update` instead of doing its
    # own copy. See gen_nx_completions.py main() for the matching note.
    _check_region(
        gen.DOCTOR_FILE,
        gen.LIB_FILES_REGION_RE,
        gen.emit_lib_files_region(manifest, "_f", include_aux=True),
        "nx-libs region (doctor)",
        failures,
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
