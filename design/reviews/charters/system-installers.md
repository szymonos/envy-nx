# Charter - `system-installers`

Root-required installers (`.assets/provision/`), `.assets/scripts/linux_setup.sh` and the other host scripts, the system checks and the non-cert fixers. They run as root with no `nix profile rollback` to undo a botched package install, so privilege discipline and per-distro parity matter most.

## What good looks like

- **A script that needs root checks `$EUID` and exits** - not a comment saying so.
- **Every distro `case` ends in a `*)` arm that errors** (`check-distro-case-arm` enforces the arm; review checks it does the right thing), and a new tool gets an arm for every supported distro.
- **Partial installs say what state they left**; `trap` cleans up where state is created.
- **No `sudo` inside an already-root script.**
- **Reruns are no-ops.** Anything not idempotent by nature is guarded by a presence check.
- **Distro detection uses the documented `sed -En '/^ID.*(...)/'` pattern.**
- **Usernames come from an argument**, never `$USER` while running as root.
- **Tests** cover tolerance of a failed step and each installer's skip-when-present path.

## What NOT to flag

- **Needing root** - these are system-scope by design.
- **bash 5 features** - these files are Linux-only (except `install_copilot.sh`, which runs on macOS too).
- **Long per-distro `case` statements** - the right shape for six distros.
- **Two Linux entry points** - see "Why two Linux entry points".
- **`curl | sh` for the Nix installer** - see "Why not checksum-pin the Nix installer".

## References

- `ARCHITECTURE.md` sections 7.1, 7.11 and 7.12
