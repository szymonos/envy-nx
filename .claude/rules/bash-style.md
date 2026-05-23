---
globs: ["*.sh", "*.bash", "*.bats", "*.zsh"]
---

# Bash style

- Shebang: `#!/usr/bin/env bash`
- Indentation: **2 spaces**; line length: **120 chars max**
- Error handling: `set -eo pipefail` for nix-path scripts (`nix/`, `.assets/lib/`, `.assets/config/shell_cfg/`) - `-u` (nounset) breaks shell-init files that source optional vars. Linux-only scripts (`.assets/scripts/`, `.assets/check/`, `.assets/provision/`, `wsl/`) may use the stricter `set -euo pipefail`. See "Bash 3.2 constraint" below for the scope split.
- Command substitution: `$(...)`, never backticks
- Functions: `snake_case`, private: `_prefixed`; prefer `local` for function-scoped variables
- Variables: `snake_case` locals, `UPPERCASE` constants/env
- Color output: `\e[31;1m` red/error, `\e[32m` green, `\e[92m` bright green, `\e[96m` cyan/info

## Runnable examples block

Every executable `.sh` and `.zsh` script must have a `: '...'` block immediately after the shebang with copy-pasteable examples. See `CONTRIBUTING.md` "Runnable examples block" for the format and rules.

## Bash 3.2 constraint

Scripts in the Nix setup path (`nix/`, `.assets/lib/`, `.assets/config/shell_cfg/`) must be compatible with bash 3.2 (macOS). No `mapfile`, `declare -A`, `${var,,}`, `declare -n`, or negative array indices. BSD `sed`/`grep` only (no `-P`, `-r`, `\s`, `\w`). Enforced by `check_bash32.py` pre-commit hook.

Linux-only scripts (`.assets/scripts/`, `.assets/check/`, `.assets/provision/`, `wsl/`) may use bash 5 features.

## Common patterns

```bash
# Distro detection
SYS_ID="$(sed -En '/^ID.*(alpine|arch|fedora|debian|ubuntu|opensuse).*/{s//\1/;p;q}' /etc/os-release)"

# Root check
if [ $EUID -ne 0 ]; then
  printf '\e[31;1mRun the script as root.\e[0m\n' >&2
  exit 1
fi
```
