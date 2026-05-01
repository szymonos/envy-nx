"""
Generate nx tab completions for bash, zsh, and PowerShell from
.assets/lib/nx_surface.json.

Outputs:
  - .assets/config/shell_cfg/completions.bash    (full file, overwritten)
  - .assets/config/shell_cfg/completions.zsh     (full file, overwritten)
  - .assets/config/pwsh_cfg/_aliases_nix.ps1     (region replacement)

Dynamic completers (all_scopes, installed_packages, theme_omp, theme_starship)
are emitted as inline shell-native code per shell - see render_completer_*().

# :example
python3 -m tests.hooks.gen_nx_completions
"""

import json
import re
import textwrap
from pathlib import Path


def _dedent(text):
    """Strip common leading whitespace; trailing newline removed."""
    return textwrap.dedent(text).strip("\n")


def _indent_block(text, prefix):
    """Re-indent each line of a dedented snippet."""
    return textwrap.indent(text, prefix)


REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST = REPO_ROOT / ".assets/lib/nx_surface.json"
BASH_OUT = REPO_ROOT / ".assets/config/shell_cfg/completions.bash"
ZSH_OUT = REPO_ROOT / ".assets/config/shell_cfg/completions.zsh"
PS_FILE = REPO_ROOT / ".assets/config/pwsh_cfg/_aliases_nix.ps1"

PS_REGION_RE = re.compile(r"#region nx-completer.*?#endregion nx-completer", re.DOTALL)

GEN_NOTICE_SH = (
    "# Generated from .assets/lib/nx_surface.json - DO NOT EDIT\n"
    "# Regenerate with: python3 -m tests.hooks.gen_nx_completions\n"
)


# ---------------------------------------------------------------------------
# helpers: walk the manifest
# ---------------------------------------------------------------------------


def all_names(verb_or_subverb):
    """Canonical name plus aliases."""
    return [verb_or_subverb["name"]] + list(verb_or_subverb.get("aliases", []))


def find_verb(manifest, name):
    for v in manifest["verbs"]:
        if name in all_names(v):
            return v
    return None


def find_subverb(verb, name):
    for sv in verb.get("subverbs", []):
        if name in all_names(sv):
            return sv
    return None


def verbs_with_subverbs(manifest):
    return [v for v in manifest["verbs"] if v.get("subverbs")]


def verbs_with_flags(manifest):
    return [v for v in manifest["verbs"] if v.get("flags")]


def verbs_with_arg_completer(manifest):
    out = []
    for v in manifest["verbs"]:
        for a in v.get("args", []):
            if a.get("completer"):
                out.append((v, a))
                break
    return out


def subverbs_with_arg_completer(manifest):
    out = []
    for v in manifest["verbs"]:
        for sv in v.get("subverbs", []):
            for a in sv.get("args", []):
                if a.get("completer"):
                    out.append((v, sv, a))
                    break
    return out


def subverbs_with_flags(manifest):
    out = []
    for v in manifest["verbs"]:
        for sv in v.get("subverbs", []):
            if sv.get("flags"):
                out.append((v, sv))
    return out


# ---------------------------------------------------------------------------
# bash emitter
# ---------------------------------------------------------------------------

BASH_COMPLETER = {
    "installed_packages": _dedent("""
        local _pkgs
        _pkgs="$(sed -n 's/^[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$HOME/.config/nix-env/packages.nix" 2>/dev/null)"
        [ -n "$_pkgs" ] && while IFS= read -r line; do COMPREPLY+=("$line"); done < <(compgen -W "$_pkgs" -- "$cur")
    """),
    "all_scopes": _dedent("""
        local _scopes _env="$HOME/.config/nix-env" _nl=$'\\n'
        _scopes="$(sed -n '/scopes[[:space:]]*=[[:space:]]*\\[/,/\\]/{ s/^[[:space:]]*"\\([^"]*\\)".*/\\1/p; }' "$_env/config.nix" 2>/dev/null | sed 's/^local_//')"
        local _f _n
        for _f in "$_env/scopes"/local_*.nix; do
          [ -f "$_f" ] || continue
          _n="$(basename "$_f" .nix)"
          _n="${_n#local_}"
          echo "$_scopes" | grep -qx "$_n" 2>/dev/null || _scopes="${_scopes:+$_scopes$_nl}$_n"
        done
        [ -n "$_scopes" ] && while IFS= read -r line; do COMPREPLY+=("$line"); done < <(compgen -W "$_scopes" -- "$cur")
    """),
    "theme_omp": _dedent("""
        while IFS= read -r line; do COMPREPLY+=("$line"); done < <(compgen -W "base nerd powerline" -- "$cur")
    """),
    "theme_starship": _dedent("""
        while IFS= read -r line; do COMPREPLY+=("$line"); done < <(compgen -W "base nerd" -- "$cur")
    """),
}


def bash_compgen(words):
    """Emit a `compgen -W` line that fills COMPREPLY."""
    return (
        f'while IFS= read -r line; do COMPREPLY+=("$line"); done '
        f'< <(compgen -W "{" ".join(words)}" -- "$cur")'
    )


def emit_bash(manifest):
    out = ["# bash tab completions for the nx command", GEN_NOTICE_SH.rstrip(), ""]
    out.append("function _nx_completions() {")
    out.append("  local cur prev")
    out.append('  cur="${COMP_WORDS[COMP_CWORD]}"')
    out.append('  prev="${COMP_WORDS[COMP_CWORD - 1]}"')
    out.append("")

    # 1. top-level verbs at COMP_CWORD == 1
    top_verbs = []
    for v in manifest["verbs"]:
        for n in all_names(v):
            if not n.startswith("-"):
                top_verbs.append(n)
    out.append('  if [ "$COMP_CWORD" -eq 1 ]; then')
    out.append(f"    {bash_compgen(top_verbs)}")

    # 2. subverbs at COMP_CWORD == 2
    for v in verbs_with_subverbs(manifest):
        sv_names = []
        for sv in v["subverbs"]:
            sv_names.extend(all_names(sv))
        for vname in all_names(v):
            out.append(
                f'  elif [ "$COMP_CWORD" -eq 2 ] && [ "$prev" = "{vname}" ]; then'
            )
            out.append(f"    {bash_compgen(sv_names)}")

    # 3. verb-level flags (currently: setup) - completed at any position >= 2
    for v in verbs_with_flags(manifest):
        flag_names = [f["long"] for f in v["flags"]]
        if v.get("flags") and any(f.get("short") for f in v["flags"]):
            flag_names.extend(f["short"] for f in v["flags"] if f.get("short"))
        for vname in all_names(v):
            out.append(
                f'  elif [ "$COMP_CWORD" -ge 2 ] && [ "${{COMP_WORDS[1]}}" = "{vname}" ]; then'
            )
            out.append(f"    {bash_compgen(flag_names)}")

    # 4. subverb flags (e.g. self update --force) at COMP_CWORD >= 3
    for v, sv in subverbs_with_flags(manifest):
        flag_names = [f["long"] for f in sv["flags"]]
        for vname in all_names(v):
            for svname in all_names(sv):
                out.append(
                    f'  elif [ "$COMP_CWORD" -ge 3 ] && [ "${{COMP_WORDS[1]}}" = "{vname}" ] '
                    f'&& [ "${{COMP_WORDS[2]}}" = "{svname}" ]; then'
                )
                out.append(f"    {bash_compgen(flag_names)}")

    # 5. subverb arg completers (e.g. nx scope show <TAB> -> scopes)
    # Group subverbs of the same verb that share a completer into one elif.
    grouped = {}  # (verb_name, completer) -> [subverb_names_with_aliases]
    for v, sv, arg in subverbs_with_arg_completer(manifest):
        key = (v["name"], arg["completer"])
        grouped.setdefault(key, []).extend(all_names(sv))
    for (vname_canon, completer), sv_names in grouped.items():
        verb = next(v for v in manifest["verbs"] if v["name"] == vname_canon)
        match_clause = " || ".join(
            f'[ "${{COMP_WORDS[2]}}" = "{n}" ]' for n in sv_names
        )
        for vname in all_names(verb):
            out.append(
                f'  elif [ "$COMP_CWORD" -ge 3 ] && [ "${{COMP_WORDS[1]}}" = "{vname}" ] '
                f"&& {{ {match_clause}; }}; then"
            )
            out.append(_indent_block(BASH_COMPLETER[completer], "    "))

    # 6. verb-level arg completers (e.g. nx remove <TAB> -> packages)
    for v, arg in verbs_with_arg_completer(manifest):
        cond = " || ".join(f'[ "${{COMP_WORDS[1]}}" = "{n}" ]' for n in all_names(v))
        out.append(f'  elif [ "$COMP_CWORD" -ge 2 ] && {{ {cond}; }}; then')
        out.append(_indent_block(BASH_COMPLETER[arg["completer"]], "    "))

    out.append("  fi")
    out.append("}")
    out.append("complete -F _nx_completions nx")
    out.append("")
    return "\n".join(out)


# ---------------------------------------------------------------------------
# zsh emitter
# ---------------------------------------------------------------------------

ZSH_PREAMBLE = """# zsh tab completions for the nx command

# Ensure the completion system is initialized so `compdef` is defined.
# macOS' default zsh setup does not run compinit, which causes
# `command not found: compdef` when this file is sourced from .zshrc.
# The guard makes the call a no-op when compinit has already run elsewhere.
if (( ! ${+functions[compdef]} )); then
  autoload -Uz compinit
  compinit -i
fi
"""

ZSH_COMPLETER = {
    "installed_packages": _dedent("""
        local -a _pkgs
        _pkgs=("${(@f)$(sed -n 's/^[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$HOME/.config/nix-env/packages.nix" 2>/dev/null)}")
        [[ -n "${_pkgs[*]}" ]] && _describe 'package' _pkgs
    """),
    "all_scopes": _dedent("""
        local _env="$HOME/.config/nix-env"
        local -a _scopes
        _scopes=("${(@f)$(sed -n '/scopes[[:space:]]*=[[:space:]]*\\[/,/\\]/{
          s/^[[:space:]]*"\\([^"]*\\)".*/\\1/p
        }' "$_env/config.nix" 2>/dev/null | sed 's/^local_//')}")
        local _f _n
        for _f in "$_env/scopes"/local_*.nix(N); do
          _n="${${_f:t:r}#local_}"
          if ! (( ${_scopes[(Ie)$_n]} )); then
            _scopes+=("$_n")
          fi
        done
        _describe 'scope name' _scopes
    """),
    "theme_omp": "_values 'theme' base nerd powerline",
    "theme_starship": "_values 'theme' base nerd",
}


def emit_zsh(manifest):
    out = [ZSH_PREAMBLE.rstrip(), GEN_NOTICE_SH.rstrip(), ""]
    out.append("function _nx() {")
    out.append("  local -a subcmds")
    out.append("  subcmds=(")
    for v in manifest["verbs"]:
        for n in all_names(v):
            if not n.startswith("-"):
                out.append(f"    '{n}:{v['summary']}'")
    out.append("  )")
    out.append("")
    out.append("  if (( CURRENT == 2 )); then")
    out.append("    _describe 'nx command' subcmds")
    out.append("    return")
    out.append("  fi")
    out.append("")
    out.append('  case "${words[2]}" in')

    # for each verb that has subverbs, flags, or per-verb arg completer
    interesting = set()
    for v in verbs_with_subverbs(manifest):
        interesting.add(v["name"])
    for v in verbs_with_flags(manifest):
        interesting.add(v["name"])
    for v, _ in verbs_with_arg_completer(manifest):
        interesting.add(v["name"])

    for v in manifest["verbs"]:
        if v["name"] not in interesting:
            continue
        names = all_names(v)
        out.append(f"  {'|'.join(names)})")

        # subverbs at CURRENT == 3
        if v.get("subverbs"):
            out.append("    if (( CURRENT == 3 )); then")
            out.append(f"      local -a {v['name']}_cmds")
            out.append(f"      {v['name']}_cmds=(")
            for sv in v["subverbs"]:
                for sn in all_names(sv):
                    out.append(f"        '{sn}:{sv['summary']}'")
            out.append("      )")
            out.append(f"      _describe '{v['name']} command' {v['name']}_cmds")

            # subverb arg completer at CURRENT >= 4 (grouped by completer)
            sv_arg = [
                (sv, a)
                for sv in v["subverbs"]
                for a in sv.get("args", [])
                if a.get("completer")
            ]
            if sv_arg:
                out.append("    elif (( CURRENT >= 4 )); then")
                out.append('      case "${words[3]}" in')
                grouped_sv = {}  # completer -> [sv_name_with_aliases]
                for sv, a in sv_arg:
                    grouped_sv.setdefault(a["completer"], []).extend(all_names(sv))
                for completer_name, names in grouped_sv.items():
                    out.append(f"      {'|'.join(names)})")
                    out.append(_indent_block(ZSH_COMPLETER[completer_name], "        "))
                    out.append("        ;;")
                out.append("      esac")

            # subverb flags at CURRENT >= 4
            sv_flags = [sv for sv in v["subverbs"] if sv.get("flags")]
            if sv_flags and not sv_arg:
                out.append("    elif (( CURRENT >= 4 )); then")
                for sv in sv_flags:
                    out.append(
                        f'      if [[ "${{words[3]}}" == "{sv["name"]}" ]]; then'
                    )
                    out.append(f"        local -a {sv['name']}_flags")
                    out.append(f"        {sv['name']}_flags=(")
                    for f in sv["flags"]:
                        out.append(f"          '{f['long']}:{f['summary']}'")
                    out.append("        )")
                    out.append(f"        _describe 'flag' {sv['name']}_flags")
                    out.append("      fi")
            elif sv_flags and sv_arg:
                # both completers and flags: fold flags into the existing CURRENT >= 4 block
                # (rare path, only matters if a subverb has both - currently none do)
                pass
            out.append("    fi")

        # verb-level flags (e.g. setup)
        if v.get("flags"):
            out.append(f"    local -a {v['name']}_flags")
            out.append(f"    {v['name']}_flags=(")
            for f in v["flags"]:
                out.append(f"      '{f['long']}:{f['summary']}'")
            out.append("    )")
            out.append(f"    _describe '{v['name']} flag' {v['name']}_flags")

        # verb-level arg completer (e.g. remove)
        for vv, a in verbs_with_arg_completer(manifest):
            if vv["name"] == v["name"]:
                out.append(_indent_block(ZSH_COMPLETER[a["completer"]], "    "))

        out.append("    ;;")

    out.append("  esac")
    out.append("}")
    out.append("compdef _nx nx")
    out.append("")
    return "\n".join(out)


# ---------------------------------------------------------------------------
# PowerShell emitter (region replacement only)
# ---------------------------------------------------------------------------

PS_COMPLETER = {
    "installed_packages": (
        '$pkgFile = "$HOME/.config/nix-env/packages.nix"\n'
        "                if (Test-Path $pkgFile) {\n"
        "                    (Get-Content $pkgFile) | ForEach-Object { "
        'if ($_ -match \'^\\s*"([^"]+)"\') { $Matches[1] } }\n'
        "                }"
    ),
    "all_scopes": (
        '$envDir = "$HOME/.config/nix-env"\n'
        '                $cfgFile = "$envDir/config.nix"\n'
        "                $scopeNames = @()\n"
        "                if (Test-Path $cfgFile) {\n"
        "                    $inScopes = $false\n"
        "                    (Get-Content $cfgFile) | ForEach-Object {\n"
        "                        if ($_ -match 'scopes\\s*=\\s*\\[') { $inScopes = $true }\n"
        '                        if ($inScopes -and $_ -match \'^\\s*"([^"]+)"\') { '
        "$scopeNames += $Matches[1] -replace '^local_', '' }\n"
        "                        if ($inScopes -and $_ -match '\\]') { $inScopes = $false }\n"
        "                    }\n"
        "                }\n"
        '                $scopesDir = "$envDir/scopes"\n'
        "                if (Test-Path $scopesDir) {\n"
        '                    Get-ChildItem "$scopesDir/local_*.nix" -ErrorAction SilentlyContinue | ForEach-Object {\n'
        "                        $n = $_.BaseName -replace '^local_', ''\n"
        "                        if ($n -notin $scopeNames) { $scopeNames += $n }\n"
        "                    }\n"
        "                }\n"
        "                $scopeNames"
    ),
    "theme_omp": "'base', 'nerd', 'powerline'",
    "theme_starship": "'base', 'nerd'",
}


def ps_quoted(items):
    return ", ".join(f"'{n}'" for n in items)


def emit_ps_region(manifest):
    """Emit the full #region nx-completer ... #endregion nx-completer block."""
    top_verbs = [
        n for v in manifest["verbs"] for n in all_names(v) if not n.startswith("-")
    ]

    lines = []
    lines.append(
        "#region nx-completer (generated from .assets/lib/nx_surface.json - "
        "regenerate with: python3 -m tests.hooks.gen_nx_completions)"
    )
    lines.append("Register-ArgumentCompleter -CommandName nx -Native -ScriptBlock {")
    lines.append("    param($wordToComplete, $commandAst, $cursorPosition)")
    lines.append("    $tokens = $commandAst.CommandElements")
    lines.append("    $pos = $tokens.Count")
    lines.append("    if ($wordToComplete) { $pos-- }")
    lines.append("")
    lines.append("    $completions = switch ($pos) {")

    # pos == 1: top-level verbs
    lines.append(f"        1 {{ {ps_quoted(top_verbs)} }}")

    # pos == 2: subverbs OR verb-level flags OR verb-level arg completer
    lines.append("        2 {")
    first = True
    for v in verbs_with_subverbs(manifest):
        sv_names = [n for sv in v["subverbs"] for n in all_names(sv)]
        kw = "if" if first else "elseif"
        lines.append(
            f"            {kw} ($tokens[1].Value -eq '{v['name']}') {{ {ps_quoted(sv_names)} }}"
        )
        first = False
    for v in verbs_with_flags(manifest):
        flag_names = [f["long"] for f in v["flags"]]
        kw = "if" if first else "elseif"
        lines.append(f"            {kw} ($tokens[1].Value -eq '{v['name']}') {{")
        lines.append(f"                {ps_quoted(flag_names)}")
        lines.append("            }")
        first = False
    for v, a in verbs_with_arg_completer(manifest):
        names_pat = ", ".join(f"'{n}'" for n in all_names(v))
        kw = "if" if first else "elseif"
        lines.append(f"            {kw} ($tokens[1].Value -in {names_pat}) {{")
        for line in PS_COMPLETER[a["completer"]].split("\n"):
            lines.append(f"                {line}")
        lines.append("            }")
        first = False
    lines.append("        }")

    # default (pos >= 3): subverb flags, subverb arg completer, verb-level flags + arg completer continuation
    lines.append("        default {")
    first = True
    for v, sv in subverbs_with_flags(manifest):
        flag_names = [f["long"] for f in sv["flags"]]
        kw = "if" if first else "elseif"
        lines.append(
            f"            {kw} ($tokens[1].Value -eq '{v['name']}' -and "
            f"$tokens[2].Value -eq '{sv['name']}') {{ {ps_quoted(flag_names)} }}"
        )
        first = False
    # verb-level flags continue at pos >= 3 (e.g. setup)
    for v in verbs_with_flags(manifest):
        flag_names = [f["long"] for f in v["flags"]]
        kw = "if" if first else "elseif"
        lines.append(f"            {kw} ($tokens[1].Value -eq '{v['name']}') {{")
        lines.append(f"                {ps_quoted(flag_names)}")
        lines.append("            }")
        first = False
    # subverb arg completers
    for v, sv, a in subverbs_with_arg_completer(manifest):
        sv_names_pat = ", ".join(f"'{n}'" for n in all_names(sv))
        kw = "if" if first else "elseif"
        lines.append(
            f"            {kw} ($tokens[1].Value -eq '{v['name']}' -and "
            f"$tokens[2].Value -in {sv_names_pat}) {{"
        )
        for line in PS_COMPLETER[a["completer"]].split("\n"):
            lines.append(f"                {line}")
        lines.append("            }")
        first = False
    # verb-level arg completers continue at pos >= 3 (e.g. remove second pkg)
    for v, a in verbs_with_arg_completer(manifest):
        names_pat = ", ".join(f"'{n}'" for n in all_names(v))
        kw = "if" if first else "elseif"
        lines.append(f"            {kw} ($tokens[1].Value -in {names_pat}) {{")
        for line in PS_COMPLETER[a["completer"]].split("\n"):
            lines.append(f"                {line}")
        lines.append("            }")
        first = False
    lines.append("        }")

    lines.append("    }")
    lines.append(
        '    $completions | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {'
    )
    lines.append(
        "        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)"
    )
    lines.append("    }")
    lines.append("}")
    lines.append("#endregion nx-completer")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def main():
    manifest = json.loads(MANIFEST.read_text())

    BASH_OUT.write_text(emit_bash(manifest))
    print(f"wrote {BASH_OUT.relative_to(REPO_ROOT)}")

    ZSH_OUT.write_text(emit_zsh(manifest))
    print(f"wrote {ZSH_OUT.relative_to(REPO_ROOT)}")

    ps_text = PS_FILE.read_text()
    new_region = emit_ps_region(manifest)
    if not PS_REGION_RE.search(ps_text):
        raise SystemExit(
            f"#region nx-completer ... #endregion nx-completer markers not found in {PS_FILE}"
        )
    new_text = PS_REGION_RE.sub(lambda _: new_region, ps_text)
    if new_text != ps_text:
        PS_FILE.write_text(new_text)
        print(f"updated nx-completer region in {PS_FILE.relative_to(REPO_ROOT)}")
    else:
        print(
            f"nx-completer region in {PS_FILE.relative_to(REPO_ROOT)} already current"
        )


if __name__ == "__main__":
    main()
