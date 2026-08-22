"""
Require `--proto '=https' --tlsv1.2` on every executing curl/wget fetch.

Why: without `--proto`, curl will happily follow a plaintext hop and pipe the
result into `sh`. Without `--tlsv1.2` it will negotiate TLS 1.0 with whatever
middlebox is in the way. The flags are house style precisely because nobody
re-derives them per script, and shellcheck has no opinion about curl's
argument list.

`--proto-redir` is deliberately NOT required. It is belt-and-braces: curl(1)
says "Protocols denied by --proto are not overridden by --proto-redir", so
`--proto '=https'` already constrains every redirect hop. Existing call sites
that pass both are fine; new ones need not.

The whole difficulty is the false-positive surface - most `curl` tokens in
this repo are not fetches. Skipped, in order:
  - `#` comments (`.assets/lib/helpers.sh` has a doc example that reads
    exactly like a violation) and the `: '...'` runnable-examples block.
  - Strings passed to an output helper: `err "  curl ... "` in
    `nix/lib/phases/bootstrap.sh` is a remediation hint, not a fetch.
  - Alias and function definitions (`alias wget='wget -c'`).
  - Package names in installer arms (`apk add ... curl`), existence probes
    (`command -v curl`, `type curl`, `for cmd in curl jq tar`,
    `has_system_cmd curl`). These need no special rule: the token is only
    treated as a fetch when it stands in COMMAND position, and in all of
    them curl is an argument.
A quoted string only puts curl in command position when the string is an
argument to an exec-ish command (`su|sh|bash|ssh|env ... -c "..."`), which is
how `.assets/provision/install_nix.sh` invokes it. That call passes its flags
through a `$curl_flags` variable, so the hook also resolves flag-carrying
variable assignments in the same file before reporting.

Indirect fetches are NOT flagged: `nix/configure/conda.sh`,
`install_gh.sh` and `install_gcloud.sh` call `download_file`, which is
compliant once at `.assets/lib/helpers.sh`. Demanding flags at those call
sites would be wrong.

wget has no `--proto` equivalent; there it requires
`--secure-protocol=TLSv1_2` instead. Prefer curl for new code.

Out of scope for v1 (not silently ignored - listed so the gap is known):
`.assets/config/vim/.vimrc` (vimscript) and
`.assets/docker/Dockerfile.{test-nix,upgrade-walk}` (needs Dockerfile parsing).

Allowed forms:
  - `curl --proto '=https' --tlsv1.2 ...` (also `--tlsv1.3`, a higher floor)
  - `wget --secure-protocol=TLSv1_2 ...`
  - flags held in a variable assigned elsewhere in the same file
  - `# tls-probe-ok: <reason>` on the invocation line, reason mandatory -
    for connectivity probes that discard the body and whose semantics the
    flags would change (a `-k` probe that must distinguish "cert rejected"
    from "unreachable"; a probe URL the user may point at http://).

# :example
python3 -m tests.hooks.check_curl_tls
# :run on specific files (as pre-commit passes them)
python3 -m tests.hooks.check_curl_tls .assets/provision/install_gcloud.sh
"""

import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# `nix/` carries the highest-value fetch in the repo (the Nix installer
# `curl | sh`); everything under `.assets/` shares the same copy-paste blast
# radius. `tests/` is excluded - bats fixtures legitimately build command
# strings that mention curl.
SCOPED_DIRS = (".assets/", "nix/")
SHELL_SUFFIXES = {".sh", ".bash", ".zsh"}

FETCH_TOOLS = ("curl", "wget")

# curl in COMMAND position: line start, a shell separator, a subshell opener, or
# the opening quote of an exec-ish `-c "..."` string. Leading keywords and
# `VAR=val` prefixes are consumed. `command curl` and `command -- curl` execute
# and so match; `command -v/-V/-p curl` is an existence probe and must not.
CMD_POS_RE = re.compile(
    r"""(?:^|[;&|(){}`"']|\$\()
        \s*
        # Bare `VAR=value` prefixes, with no wrapper at all:
        # `DEBIAN_FRONTEND=noninteractive curl ...` is a plain fetch.
        (?:[A-Za-z_]\w*=\S*\s+)*
        (?:
            # Execution wrappers that legitimately carry their own options, so
            # `sudo -u "$user" curl ...` still reaches the curl token.
            (?:sudo|exec|time|nohup|env|_io_run)\s+
              (?:-[A-Za-z-]+(?:[=\s]+(?:"[^"]*"|'[^']*'|\S+))?\s+)*
              (?:[A-Za-z_]\w*=\S*\s+)*
          |
            # Bare keywords. `command` belongs HERE, not above: consuming its
            # options would make `command -v curl` - an existence probe, not a
            # fetch - look like an invocation.
            (?:!|if|elif|while|until|then|do|else)\s+
              (?:[A-Za-z_]\w*=\S*\s+)*
          |
            # `command` executes its target, so `command -- curl` is a fetch.
            # Only -v/-V/-p make it an existence probe, and those must NOT
            # match - hence the negative lookahead rather than a blanket
            # option-consumer.
            command\s+(?!-[vVp]\b)(?:--\s+)?
        )*
        (curl|wget)\b""",
    re.VERBOSE,
)
# `su - user -c "..."`, `bash -lc "..."`, `ssh host -c "..."`: the quoted string
# is executed, so curl inside it is a real invocation.
EXEC_C_RE = re.compile(
    r"\b(?:su|sh|bash|zsh|dash|ksh|ssh|env|runuser|doas)\b[^;|&]*?\s-[a-z]*c\s"
)
# Output helpers - their quoted argument is printed, never executed.
OUTPUT_FN_RE = re.compile(
    r"^\s*(?:err|warn|info|ok|die|note|log|printf|echo|print|_io_step)\s+[\"']"
)
ALIAS_RE = re.compile(r"^\s*alias\s+")

# `--proto '=https'` - the VALUE matters, not just the flag's presence. A bare
# `--proto` check would accept `--proto '=http'` or `--proto all`; a prefix
# match would accept `--proto '=https,http'`. Both grant exactly what the rule
# denies, so the value must be EXACTLY `=https`. Quotes are optional in shell.
# Not `--proto-redir`.
PROTO_RE = re.compile(
    r"--proto(?![-\w])[=\s]+(?:'=https'|\"=https\"|=https(?![\w,+-]))"
)
# `-k` / `--insecure` disables certificate verification outright, so a fetch can
# carry every required flag and still be unsafe. Bundled forms like `-#Lko`
# hide it, hence the character-class match rather than a literal `-k`.
INSECURE_RE = re.compile(r"(?:^|\s)(?:--insecure\b|-[A-Za-z]*k[A-Za-z]*(?=\s|$))")
TLS_RE = re.compile(r"--tlsv1\.[23]\b")
WGET_TLS_RE = re.compile(r"--secure-protocol=TLSv1_[23]\b")

ASSIGN_RE = re.compile(
    r"^\s*(?:local\s+|export\s+|readonly\s+|declare\s+-\S+\s+)?([A-Za-z_]\w*)=(.*)$"
)
VAR_REF_RE = re.compile(r"\$\{?([A-Za-z_]\w*)")

SUPPRESS_RE = re.compile(r"#\s*tls-probe-ok:\s*(\S.*)$")
MARKER = "# tls-probe-ok:"

EXAMPLE_OPEN = ": '"
EXAMPLE_CLOSE = "'"


def _has_live_substitution(code: str) -> bool:
    """
    True when `$(` appears outside a single-quoted literal.

    An output helper's argument is printed, not executed - but a command
    substitution in it is evaluated first, so `info "$(curl ...)"` is a real
    fetch. Inside single quotes nothing is expanded, so `err 'see $(curl ...)'`
    is literal message text and flagging it would be a false positive on
    exactly the documentation strings this hook is meant to skip.
    """
    in_single = False
    i = 0
    while i < len(code):
        ch = code[i]
        if ch == "\\":
            i += 2
            continue
        if ch == "'":
            in_single = not in_single
        elif not in_single and ch == "$" and code[i + 1 : i + 2] == "(":
            return True
        i += 1
    return False


def _scan_root() -> Path:
    """Tree to scan / scope against. Overridable so bats can point at a fixture."""
    return Path(os.environ.get("CHECK_CURL_TLS_ROOT", REPO_ROOT))


def _rel(path: Path) -> str:
    """Repo-relative path when the file lives under the scan root, else as given."""
    try:
        return path.resolve().relative_to(_scan_root().resolve()).as_posix()
    except ValueError:
        return path.as_posix()


def _in_scope(path: Path) -> bool:
    """True for shell scripts under the scoped dirs (suffix-only when outside)."""
    if path.suffix not in SHELL_SUFFIXES or not path.is_file():
        return False
    try:
        rel = path.resolve().relative_to(_scan_root().resolve()).as_posix()
    except ValueError:
        # Outside the scan root (a bats fixture in a temp dir, or ad-hoc use on
        # an arbitrary script): scope by suffix alone.
        return True
    return any(rel.startswith(d) for d in SCOPED_DIRS)


def _strip_comment(line: str) -> str:
    """
    Drop a trailing `#` comment, honouring single and double quotes.

    `#` only opens a comment at line start or after whitespace, which keeps
    curl's `-#Lo` progress flag and `-w '%{http_code}'` intact.
    """
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


def _logical_lines(text: str) -> list[tuple[int, str, str]]:
    r"""
    Return (lineno, raw_joined, code) with examples blocks and comments gone.

    `raw_joined` keeps comments so suppression markers stay visible; `code` is
    what the matchers run against. Backslash continuations are merged so a
    `curl ... \` / URL-on-the-next-line invocation is judged as one command.
    """
    lines = text.splitlines()
    n = len(lines)
    # Blank out the `: '...'` runnable-examples block (from a line that is
    # exactly `: '` to the next line that is exactly `'`).
    skip = [False] * n
    i = 0
    while i < n:
        if lines[i].strip() == EXAMPLE_OPEN:
            j = i + 1
            while j < n and lines[j].strip() != EXAMPLE_CLOSE:
                j += 1
            for k in range(i, min(j + 1, n)):
                skip[k] = True
            i = j + 1
            continue
        i += 1

    out: list[tuple[int, str, str]] = []
    i = 0
    while i < n:
        if skip[i]:
            i += 1
            continue
        start = i
        raw_parts = [lines[i]]
        while (
            i < n
            and lines[i].rstrip().endswith("\\")
            and not lines[i].rstrip().endswith("\\\\")
        ):
            i += 1
            if i < n and not skip[i]:
                raw_parts.append(lines[i])
        raw = "\n".join(raw_parts)
        code = " ".join(_strip_comment(p).rstrip().rstrip("\\") for p in raw_parts)
        out.append((start + 1, raw, code))
        i += 1
    return out


def _flag_vars(logical: list[tuple[int, str, str]]) -> tuple[set[str], set[str]]:
    """
    Partition flag-carrying variables into (compliant, insecure).

    A value carrying `-k` never counts as compliant however many required flags
    sit beside it - otherwise `f="--proto '=https' --tlsv1.2 --insecure"` would
    whitelist every `curl $f` in the file, and the `-k` check on the invocation
    line cannot see it because the flags live on the assignment line.
    """
    compliant: set[str] = set()
    insecure: set[str] = set()
    for _, _, code in logical:
        m = ASSIGN_RE.match(code)
        if not m:
            continue
        name, value = m.group(1), m.group(2)
        if INSECURE_RE.search(value):
            insecure.add(name)
        elif PROTO_RE.search(value) and TLS_RE.search(value):
            compliant.add(name)
    return compliant, insecure


def _invocations(code: str) -> list[str]:
    """Tools invoked in command position on this logical line."""
    tools: list[str] = []
    for m in CMD_POS_RE.finditer(code):
        opener = code[m.start()]
        if opener in "\"'" and not EXEC_C_RE.search(code[: m.start()]):
            # A quoted string that nothing executes - a message, not a fetch.
            continue
        tools.append(m.group(1))
    return tools


def _scan(path: Path) -> list[tuple[int, str, str]]:
    """Return (lineno, line, reason) for every unguarded executing fetch."""
    offenders: list[tuple[int, str, str]] = []
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return offenders

    logical = _logical_lines(text)
    flag_vars, insecure_vars = _flag_vars(logical)

    for lineno, raw, code in logical:
        # An output helper's argument is printed, not executed - but a command
        # substitution inside it IS evaluated first, so `info "$(curl ...)"`
        # carries a real fetch. Only skip the line when it holds no `$(`.
        if OUTPUT_FN_RE.match(code) and not _has_live_substitution(code):
            continue
        if ALIAS_RE.match(code):
            continue
        tools = _invocations(code)
        if not tools:
            continue
        if MARKER in raw:
            if not SUPPRESS_RE.search(raw):
                offenders.append(
                    (
                        lineno,
                        raw.splitlines()[0].strip(),
                        "`# tls-probe-ok:` marker carries no reason text",
                    )
                )
            continue
        referenced = VAR_REF_RE.findall(code)
        if any(name in insecure_vars for name in referenced):
            offenders.append(
                (
                    lineno,
                    raw.splitlines()[0].strip(),
                    "curl fetch uses `-k`/`--insecure` through a variable, "
                    "disabling certificate verification",
                )
            )
            continue
        if any(name in flag_vars for name in referenced):
            continue
        for tool in tools:
            if tool == "wget":
                if not WGET_TLS_RE.search(code):
                    offenders.append(
                        (
                            lineno,
                            raw.splitlines()[0].strip(),
                            "wget fetch without `--secure-protocol=TLSv1_2`",
                        )
                    )
                continue
            if INSECURE_RE.search(code):
                offenders.append(
                    (
                        lineno,
                        raw.splitlines()[0].strip(),
                        "curl fetch uses `-k`/`--insecure`, disabling certificate "
                        "verification",
                    )
                )
                continue
            missing = [
                flag
                for flag, rx in (("--proto '=https'", PROTO_RE), ("--tlsv1.2", TLS_RE))
                if not rx.search(code)
            ]
            if missing:
                offenders.append(
                    (
                        lineno,
                        raw.splitlines()[0].strip(),
                        f"curl fetch missing {' and '.join(missing)}",
                    )
                )
    return offenders


def main(argv: list[str] | None = None) -> int:
    """Check shell scripts for curl/wget fetches without the TLS flag set."""
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

    print("Executing curl/wget fetch without the required TLS flags.", file=sys.stderr)
    print(
        "Without `--proto '=https'` curl will follow a plaintext hop; without\n"
        "`--tlsv1.2` it will negotiate TLS 1.0 with any middlebox in the way.\n"
        "See ARCHITECTURE.md section 7.12.\n",
        file=sys.stderr,
    )
    for path, lineno, line, reason in failures:
        print(f"  {_rel(path)}:{lineno}: {line}", file=sys.stderr)
        print(f"      {reason}", file=sys.stderr)

    print(
        "\nFixes (in order of preference):\n"
        "  1. Add the flags: `curl --proto '=https' --tlsv1.2 -sSf -L <url>`.\n"
        "     They are free on any https endpoint. `--proto-redir` is optional -\n"
        "     `--proto` already constrains the redirect hops.\n"
        "  2. Fetch through `download_file` (.assets/lib/helpers.sh) instead -\n"
        "     it is compliant once, with retry and status-code handling.\n"
        "  3. Only for a connectivity probe whose body is discarded and whose\n"
        "     meaning the flags would change (a `-k` probe distinguishing\n"
        "     'cert rejected' from 'unreachable', or a user-overridable probe\n"
        "     URL that may be http://), suppress with `# tls-probe-ok: <reason>`\n"
        "     on the invocation line. The reason is mandatory.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
