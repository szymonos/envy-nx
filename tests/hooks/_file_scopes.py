"""
Single source of truth for shell-rule hook file scopes.

Multiple shell-lint hooks (check_zsh_compat, check_bash32,
check_no_aliased_builtins) need to know "which files get sourced into the
user's interactive shell" vs "which files run as subprocesses during
nix/setup.sh on bare macOS." Those categories overlap but are distinct;
hardcoding the lists separately in each hook AND each .pre-commit-config.yaml
regex made it easy to silently miss a new file in one place.

This module defines the categories once for hook code. The corresponding
.pre-commit-config.yaml `files:` regexes still live next to each hook in
that file (pre-commit can't import Python); they carry a comment naming
the category here so the next contributor knows where to mirror an edit.

Add a file here when:
  - You add a new file under `.assets/` that gets sourced into the
    interactive shell -> INTERACTIVE_SHELL.

The category for setup-path (nix/setup.sh subprocess) files lives implicitly
in the existing check-bash32 regex; widening _file_scopes.py to own that
list too is queued in design/cleanup_queue.md.

See ARCHITECTURE.md §3c (nx CLI sourcing), §3e (managed blocks), §7.1-§7.3
(file-scope constraints).
"""

from __future__ import annotations

# Files sourced into the user's interactive shell (bash, zsh) via rc-file
# managed blocks OR via the lazy `nx()` wrapper. They:
#   - Inherit the user's aliases (use `command mv`/`command cp` to bypass).
#   - Must be zsh-compatible (no bare `name() {`, no `BASH_SOURCE` without
#     a guarded fallback, no for-loop over unquoted globs).
#   - Must be bash-3.2 compatible (stock macOS terminal).
INTERACTIVE_SHELL: tuple[str, ...] = (
    # User-facing config sourced from ~/.bashrc / ~/.zshrc
    ".assets/config/shell_cfg/aliases_git.sh",
    ".assets/config/shell_cfg/aliases_kubectl.sh",
    ".assets/config/shell_cfg/aliases_nix.sh",
    ".assets/config/shell_cfg/functions.sh",
    # nx CLI - sourced lazily by `nx()` wrapper, all five always together
    ".assets/lib/nx.sh",
    ".assets/lib/nx_pkg.sh",
    ".assets/lib/nx_scope.sh",
    ".assets/lib/nx_profile.sh",
    ".assets/lib/nx_lifecycle.sh",
    # Doctor, profile block helper, generic helpers - sourced transitively
    ".assets/lib/nx_doctor.sh",
    ".assets/lib/profile_block.sh",
    ".assets/lib/helpers.sh",
    # certs.sh is sourced from $HOME/.config/shell/certs.sh in functions.sh
    ".assets/lib/certs.sh",
    # env_block.sh is sourced by nx_profile.sh
    ".assets/lib/env_block.sh",
)

# Alias for the alias-builtins hook. Reuses INTERACTIVE_SHELL as-is today;
# named separately so future divergence (e.g. a subset that needs a different
# rule) doesn't require touching the importer.
ALIASED_BUILTINS_FILES: tuple[str, ...] = INTERACTIVE_SHELL
