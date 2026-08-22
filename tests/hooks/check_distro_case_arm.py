r"""
Require a non-empty `*)` default arm on every distro `case` statement.

Why: the installers under `.assets/provision/` all branch on a distro id
extracted from `/etc/os-release` by the same `sed -En '/^ID.*(alpine|arch|
fedora|debian|ubuntu|opensuse).*/{s//\\1/;p;q}'` idiom. When the sed matches
nothing (Gentoo, NixOS, RHEL, an unknown container base), the variable is the
EMPTY STRING - not the distro name. A `case` without a `*)` arm then falls
straight through: bash runs no arm, `set -e` sees no failure, and the script
exits 0. The user is told "installing docker", nothing is installed, and the
caller reports success. `install_gh.sh` additionally reached its apt
signing-key block only for debian/ubuntu, so on an unknown distro it also
skipped the key and left a sources list nobody could verify.

The shape spreads because every new installer is a copy of the previous one,
and shellcheck cannot see it - a `case` with no default is valid shell.

Scope is CONTENT-BASED, not directory-based. A file is in scope when it
assigns a variable from a distro-id alternation group (the canonical six-way
group, or a deliberately narrowed variant such as `fix_azcli_certs.sh`'s
`(fedora|debian|ubuntu|opensuse)`). Directory scoping is exactly how the next
copy-paste sibling escapes the net. Within such a file only `case` statements
whose SUBJECT is one of those distro variables are checked - a subcommand
dispatch like `case "${1:-}" in` is left alone.

Deliberately NOT checked: whether all six distro arms are present. That would
false-positive on `install_docker.sh` (no alpine arm on purpose),
`fix_azcli_certs.sh` (4 arms - `rpm -ql`/`dpkg-query -L` do not apply to
alpine/arch) and `functions.sh` (5 arms).

Allowed forms:
  - `*)` as the LAST arm, with a non-empty body (the repo's house arm reads
    the raw `ID=` field and exits 1 with two red messages).
  - `case $SYS_ID in # distro-case-ok: <reason>` - suppression, reason
    mandatory. Use it when falling through is the design, e.g.
    `check_ssl.sh` degrades to a wget/python3 probe ladder and its caller
    parses the printed word.

# :example
python3 -m tests.hooks.check_distro_case_arm
# :run on specific files (as pre-commit passes them)
python3 -m tests.hooks.check_distro_case_arm .assets/provision/install_gh.sh
"""

import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# Dirs walked on a bare (no-argv) invocation. Explicitly-passed files are
# scoped by content alone, so pre-commit can hand us anything.
SCOPED_DIRS = (".assets/", "nix/", "wsl/", "modules/")
SHELL_SUFFIXES = {".sh", ".bash", ".zsh"}

DISTRO_IDS = ("alpine", "arch", "fedora", "debian", "ubuntu", "opensuse")
_IDS = "|".join(DISTRO_IDS)

# An alternation group of >= 2 distro ids: `(alpine|arch|fedora|debian|ubuntu|
# opensuse)` and the narrowed variants in upgrade_system.sh, fix_azcli_certs.sh,
# functions.sh and fix_wsl_dns.sh. Both the `sed -En` and the `grep -oP` spelling
# of the detection produce this shape.
DISTRO_ALT_RE = re.compile(rf"\(\s*(?:{_IDS})(?:\s*\|\s*(?:{_IDS}))+\s*\)")
ASSIGN_RE = re.compile(
    r"^\s*(?:local\s+|export\s+|readonly\s+|declare\s+-\S+\s+)?([A-Za-z_]\w*)="
)

CASE_RE = re.compile(r"^\s*case\s+(\S.*?)\s+in\b")
ESAC_RE = re.compile(r"(?:^|[\s;&|(){}])esac(?:$|[\s;&|)])")
# A case-pattern arm line: `alpine)`, `fedora | opensuse)`, `*)`, `*) body ;;`.
# `[^()#]*?` cannot cross a `(`, which is what keeps body lines such as
# `raw_id="$(sed -n 's/^ID=//p' ...)"` from parsing as an arm.
ARM_RE = re.compile(r"^\s*\(?\s*([^()#]*?)\)(.*)$")
HEREDOC_RE = re.compile(r"<<-?\s*[\"']?([A-Za-z_]\w*)[\"']?")

SUPPRESS_RE = re.compile(r"#\s*distro-case-ok:\s*(\S.*)$")
MARKER = "# distro-case-ok:"


def _scan_root() -> Path:
    """Tree to scan / scope against. Overridable so bats can point at a fixture."""
    return Path(os.environ.get("CHECK_DISTRO_CASE_ROOT", REPO_ROOT))


def _rel(path: Path) -> str:
    """Repo-relative path when the file lives under the scan root, else as given."""
    try:
        return path.resolve().relative_to(_scan_root().resolve()).as_posix()
    except ValueError:
        return path.as_posix()


def _distro_vars(text: str) -> set[str]:
    """Names of variables assigned from a distro-id alternation group."""
    names: set[str] = set()
    for line in text.splitlines():
        if not DISTRO_ALT_RE.search(line):
            continue
        m = ASSIGN_RE.match(line)
        if m:
            names.add(m.group(1))
    return names


def _in_scope(path: Path) -> bool:
    """True when the file is a shell script that detects a distro id."""
    if path.suffix not in SHELL_SUFFIXES or not path.is_file():
        return False
    try:
        return bool(_distro_vars(path.read_text(errors="replace")))
    except OSError:
        return False


def _strip_comment(line: str) -> str:
    """Drop a trailing `#` comment, honouring single and double quotes."""
    out: list[str] = []
    in_s = in_d = False
    prev = ""
    for ch in line:
        if ch == "'" and not in_d:
            in_s = not in_s
        elif ch == '"' and not in_s:
            in_d = not in_d
        elif ch == "#" and not in_s and not in_d and (prev == "" or prev.isspace()):
            break
        out.append(ch)
        prev = ch
    return "".join(out)


def _code_lines(text: str) -> list[str]:
    """Comment-stripped lines with heredoc bodies blanked out."""
    lines = text.splitlines()
    out: list[str] = []
    terminator: str | None = None
    for line in lines:
        if terminator is not None:
            if line.strip() == terminator:
                terminator = None
            out.append("")
            continue
        code = _strip_comment(line)
        out.append(code)
        m = HEREDOC_RE.search(code)
        if m:
            terminator = m.group(1)
    return out


def _is_case_pattern(pat: str) -> bool:
    """Reject `)`-bearing body lines that are not case patterns."""
    pat = pat.strip()
    if not pat or "=" in pat:
        return False
    alts = [a.strip() for a in pat.split("|")]
    return all(a and not re.search(r"\s", a) for a in alts)


def _subject_var(subject: str) -> str | None:
    """Variable name referenced by a `case <subject> in` expression."""
    m = re.search(r"\$\{?([A-Za-z_]\w*)", subject)
    return m.group(1) if m else None


def _is_default(pat: str) -> bool:
    """True when any alternative of the pattern is the catch-all `*`."""
    return "*" in [a.strip() for a in pat.split("|")]


def _judge(arms: list[tuple[int, str, str]]) -> str:
    """Empty string when the arm list is well-formed, else the failure reason."""
    if not arms:
        return "no `*)` default arm (the case has no arms at all)"
    if not _is_default(arms[-1][1]):
        if any(_is_default(pat) for _, pat, _ in arms):
            return "`*)` is not the last arm - the arms after it are dead code"
        return "no `*)` default arm - an unmatched distro id falls through, exit 0"
    body = arms[-1][2]
    if not any(
        ln.strip() and ln.strip() not in {";;", ";&", ";;&"} for ln in body.splitlines()
    ):
        return "`*)` arm has an empty body - it silences the fall-through"
    return ""


def _verdict(frame: dict, raw: list[str]) -> tuple[int, str, str] | None:
    """Judge one closed `case` frame; None when it is fine or out of scope."""
    if not frame["tracked"]:
        return None
    case_line = raw[frame["line"]]
    if MARKER in case_line:
        if SUPPRESS_RE.search(case_line):
            return None
        reason = "`# distro-case-ok:` marker carries no reason text"
    else:
        reason = _judge(frame["arms"])
    return (frame["line"] + 1, case_line.strip(), reason) if reason else None


def _open_frame(lineno: int, subject: str, distro_vars: set[str]) -> dict:
    """New bookkeeping frame for a `case` statement opening at `lineno`."""
    var = _subject_var(subject)
    return {"line": lineno, "tracked": bool(var) and var in distro_vars, "arms": []}


def _inline_arms(lineno: int, tail: str) -> list[tuple[int, str, str]]:
    """Arms of a single-line `case x in a) body ;; *) body ;; esac`."""
    arms: list[tuple[int, str, str]] = []
    for chunk in tail.rsplit("esac", 1)[0].split(";;"):
        if not chunk.strip():
            continue
        am = ARM_RE.match(" " + chunk)
        if am and _is_case_pattern(am.group(1)):
            arms.append((lineno, am.group(1).strip(), am.group(2)))
    return arms


def _absorb(frame: dict, lineno: int, line: str) -> None:
    """Record `line` as a new arm of `frame`, or as body of its current arm."""
    am = ARM_RE.match(line)
    if am and _is_case_pattern(am.group(1)):
        frame["arms"].append((lineno, am.group(1).strip(), am.group(2)))
    elif frame["arms"]:
        idx, pat, body = frame["arms"][-1]
        frame["arms"][-1] = (idx, pat, body + "\n" + line)


def _scan(path: Path) -> list[tuple[int, str, str]]:
    """Return (lineno, case_line, reason) for every offending distro `case`."""
    offenders: list[tuple[int, str, str]] = []
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return offenders

    distro_vars = _distro_vars(text)
    if not distro_vars:
        return offenders

    raw = text.splitlines()
    # One frame per open `case`; only frames whose subject is a distro variable
    # are judged, so a subcommand dispatch (`case "${1:-}" in`) is ignored.
    stack: list[dict] = []

    for i, line in enumerate(_code_lines(text)):
        m = CASE_RE.match(line)
        if m:
            frame = _open_frame(i, m.group(1), distro_vars)
            tail = line[m.end() :]
            if ESAC_RE.search(tail):
                frame["arms"] = _inline_arms(i, tail)
                stack.append(frame)
            else:
                stack.append(frame)
                continue
        if not stack:
            continue
        if m or ESAC_RE.search(line):
            verdict = _verdict(stack.pop(), raw)
            if verdict:
                offenders.append(verdict)
            continue
        _absorb(stack[-1], i, line)

    return offenders


def main(argv: list[str] | None = None) -> int:
    """Check distro `case` statements for a non-empty, last-position `*)` arm."""
    args = argv or []
    root = _scan_root()
    if args:
        files = [Path(p) for p in args if _in_scope(Path(p))]
    else:
        files = []
        for d in SCOPED_DIRS:
            base = root / d.rstrip("/")
            if base.is_dir():
                files.extend(p for p in sorted(base.rglob("*")) if _in_scope(p))

    failures: list[tuple[Path, int, str, str]] = []
    for f in files:
        for lineno, line, reason in _scan(f):
            failures.append((f, lineno, line, reason))

    if not failures:
        return 0

    print(
        "Distro `case` statement without a usable `*)` default arm.",
        file=sys.stderr,
    )
    print(
        "An unmatched /etc/os-release ID leaves the distro variable EMPTY, every\n"
        "arm is skipped, and the installer exits 0 having installed nothing.\n"
        "See ARCHITECTURE.md section 7.11.\n",
        file=sys.stderr,
    )
    for path, lineno, line, reason in failures:
        print(f"  {_rel(path)}:{lineno}: {line}", file=sys.stderr)
        print(f"      {reason}", file=sys.stderr)

    print(
        "\nFixes (in order of preference):\n"
        "  1. Add the house `*)` arm - copy it verbatim from\n"
        "     .assets/provision/install_podman.sh (reads the raw ID= field,\n"
        "     prints two red messages to stderr, exits 1). Keep it byte-identical\n"
        "     across installers so the next copy-paste inherits a correct arm.\n"
        "  2. If the script must degrade gracefully rather than fail (its caller\n"
        "     parses the output), give `*)` a body that produces the documented\n"
        '     fallback value - see .assets/check/check_ssl.sh\'s "unknown".\n'
        "  3. Only if falling through really is the design, suppress with\n"
        "     `# distro-case-ok: <reason>` on the `case` line. The reason is\n"
        "     mandatory and must say what handles the unmatched distro instead.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
