# Charter - `system-installers` shard (root-required installers)

System-scope installers run as root and bring the rest of the tool to life. Failure here can leave a system in a half-installed state with no rollback path - unlike user-scope nix, there's no `nix profile rollback` to undo a botched `apt install`. Privilege boundary discipline (no surprise sudo, no setuid creep) and per-distro arm parity are the watched concerns.

## Scope

| File                                       | Role                                                                   |
| ------------------------------------------ | ---------------------------------------------------------------------- |
| `.assets/scripts/linux_setup.sh`           | System setup orchestrator; calls install_base.sh, install_nix.sh, etc. |
| `.assets/provision/install_base.sh`        | Base system package installation per distro                            |
| `.assets/provision/install_nix.sh`         | One-time nix bootstrap (Determinate Systems installer)                 |
| `.assets/provision/install_zsh.sh`         | zsh shell install (system-prefer tier)                                 |
| `.assets/provision/install_gh.sh`          | GitHub CLI install                                                     |
| `.assets/provision/install_podman.sh`      | podman container runtime install                                       |
| `.assets/provision/install_distrobox.sh`   | distrobox install (with username arg)                                  |
| `.assets/provision/install_copilot.sh`     | GitHub Copilot CLI install                                             |
| `.assets/provision/install_azurecli_uv.sh` | Azure CLI install via uv                                               |

**Out of scope:** the WSL host-side equivalents (→ `wsl-orchestration` shard); per-scope post-install scripts under `nix/configure/` (those run user-scope after nix is up); the orchestration that *calls* these installers (→ `orchestration` shard).

## What "good" looks like

- **Every script that requires root explicitly checks `$EUID` and refuses to run otherwise**, with the documented red-error pattern from [`.claude/CLAUDE.md` → Common Bash Patterns](../../../.claude/CLAUDE.md). Not a comment "must be run as root" - a check that exits.
- **Per-distro arms are exhaustive - no silent fall-through.** The `case "$SYS_ID"` for alpine/arch/fedora/debian/ubuntu/opensuse must end with a `*)` arm that prints an error and exits non-zero, not silently succeeds. Adding a new tool means adding the arm for every supported distro.
- **Failures are atomic where possible; partial installs print actionable cleanup.** If `apt install foo bar` fails halfway, the user needs to know what state they're in. `set -euo pipefail` is on; `trap` for cleanup is appropriate where state is created.
- **No unnecessary `sudo` within already-root scripts.** `install_base.sh` runs as root; `sudo apt install` inside it is a smell - the script is already privileged. Internal `sudo` invocations cause env-preservation surprises (`PATH`, `HOME` differ).
- **Each installer is rerunnable.** A second run after success is a no-op (or near-no-op). `apt install` is idempotent; `curl | sh` for tools that don't check existence are not - guard with a presence check.
- **Distro detection uses the documented sed pattern** from [`.claude/CLAUDE.md` → Common Bash Patterns](../../../.claude/CLAUDE.md): `sed -En '/^ID.*(alpine|arch|fedora|debian|ubuntu|opensuse).*/{s//\1/;p;q}' /etc/os-release`. Don't reinvent.
- **Network operations enforce TLS 1.2+** (`curl --proto '=https' --tlsv1.2`). `wget` calls use equivalent guards.
- **Username arg handling is consistent across scripts that need it** (e.g., `install_distrobox.sh` - pass via `$1`, validate, never default to `$USER` when running as root since `$USER` is `root`).

## What NOT to flag

- **The need for root itself.** These are system-scope by design.
- **bash 5+ usage in these files.** Linux-only scripts can use bash 4+ features per [`.claude/CLAUDE.md`](../../../.claude/CLAUDE.md). The bash 3.2 constraint applies only to scripts that run on macOS.
- **Per-distro case-statement length.** Necessary surface area, not bloat. A 6-arm case is the right shape for 6 distros.
- **`linux_setup.sh` as a separate entry point from `nix/setup.sh`.** See [`docs/decisions.md` → "Why two Linux entry points"](../../../docs/decisions.md#why-two-linux-entry-points-linux_setupsh-and-nixsetupsh). Suggestions to collapse them are out of scope.
- **`curl | sh` for the Determinate Nix installer.** See [`docs/decisions.md` → "Why not checksum-pin the Nix installer"](../../../docs/decisions.md#why-not-checksum-pin-the-nix-installer).
- **Anything already in [`design/reviews/accepted.md`](../accepted.md).**

## Severity rubric

| Level    | Definition                                                                                                                        | Examples                                                                                                                            |
| -------- | --------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| critical | Privilege escalation; setuid creep; root operation that can't be undone (overwrites user files, removes packages user installed). | A script that takes a path arg and `rm -rf`s it without validation; a setuid binary installed without justification.                |
| high     | Per-distro arm missing or broken; root check absent on a script that needs it; partial-install state with no recovery path.       | New `install_*.sh` that has only debian and ubuntu arms; root-required script runs without `$EUID` check and silently does nothing. |
| medium   | Internal unnecessary `sudo`; missing TLS guard on network call; non-idempotent install (second run errors).                       | `sudo apt install` inside `install_base.sh` (already root); `curl http://...` without `--proto '=https' --tlsv1.2`.                 |
| low      | Comment rot, missing runnable-examples block, distro-detection pattern reimplemented inline.                                      | `# Install for Ubuntu` on a script that supports six distros; `if [ -f /etc/debian_version ]` instead of the documented sed.        |

## Categories

| Category        | Use for                                                                            |
| --------------- | ---------------------------------------------------------------------------------- |
| correctness     | An installer does the wrong thing on some distro, or in some pre-state.            |
| security        | Privilege boundary violation, command injection, weakened TLS, untrusted source.   |
| maintainability | Per-distro arm drift; reinventing distro detection; missing root check.            |
| testability     | Installer cannot be tested without actually being root (no mock seam).             |
| docs            | Help text wrong, runnable-examples block stale, distro-support matrix out of date. |

## References

- [`docs/decisions.md` → "Why two Linux entry points"](../../../docs/decisions.md#why-two-linux-entry-points-linux_setupsh-and-nixsetupsh)
- [`docs/decisions.md` → "Why three package tiers, not 'everything via nix'"](../../../docs/decisions.md#why-three-package-tiers-not-everything-via-nix)
- [`docs/decisions.md` → "Why not checksum-pin the Nix installer"](../../../docs/decisions.md#why-not-checksum-pin-the-nix-installer)
- [`.claude/CLAUDE.md` → Common Bash Patterns](../../../.claude/CLAUDE.md) - distro detection, root check
- [`design/reviews/accepted.md`](../accepted.md) - defers and disputes for this shard

## Charter version

- v1 (2026-05-09) - initial draft. Expect refinement after the first `/review system-installers` cycle.
