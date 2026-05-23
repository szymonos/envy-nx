# Bash 3.2 compatibility on nix-path scripts

macOS ships bash 3.2 permanently (Apple won't update due to GPLv3). The setup script must work with what the OS provides out of the box - requiring bash 5 would mean users need a setup tool to run the setup tool.

**Constraint:** No `mapfile`, `readarray`, `declare -A`, `${var,,}`, `${var^^}`, `declare -n`, or negative array indices in nix-path files. Use `while IFS= read -r` loops, space-delimited strings with helpers, and `tr` for case conversion. BSD `sed`/`grep` only (no `-P`, `-r`, `\s`, `\w`). Enforced by `check_bash32.py` pre-commit hook and macOS CI. Linux-only scripts may use bash 5 features.

**Scope:** `nix/**/*.sh`, `.assets/lib/*.sh`, `.assets/config/shell_cfg/*.sh`
