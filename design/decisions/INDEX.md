# Decision Index

Agent-readable decision records. Each file is a short constraint extract; the full persuasion narratives live in [`docs/decisions.md`](../../docs/decisions.md) (maintained separately by the author).

New decisions are created by the [`grill-with-docs`](../../.claude/skills/grill-with-docs/SKILL.md) skill or via `Codified-Decision:` commit trailers on merged PRs.

| #    | Decision                         | Scope                                                     | File                                |
| ---- | -------------------------------- | --------------------------------------------------------- | ----------------------------------- |
| 0001 | Bash 3.2 on nix-path scripts     | `nix/**`, `.assets/lib/`, `.assets/config/shell_cfg/`     | [0001](0001-bash-32-compat.md)      |
| 0002 | Three package tiers              | `nix/scopes/`, `.assets/provision/`                       | [0002](0002-three-package-tiers.md) |
| 0003 | Managed blocks, not append-style | `.assets/lib/nx_profile.sh`, `nix/lib/phases/profiles.sh` | [0003](0003-managed-blocks.md)      |
| 0004 | Phase-based orchestration        | `nix/lib/phases/`, `nix/lib/io.sh`, `tests/bats/`         | [0004](0004-phase-orchestration.md) |
| 0005 | JSON as shared schema format     | `.assets/lib/scopes.json`, `.assets/lib/nx_surface.json`  | [0005](0005-json-shared-schema.md)  |
| 0006 | Nix, not Homebrew                | `nix/**`, `.assets/lib/scopes.*`                          | [0006](0006-nix-not-homebrew.md)    |
| 0007 | Bash end-to-end, not Python      | `nix/setup.sh`, `.assets/lib/nx*.sh`                      | [0007](0007-bash-not-python.md)     |
| 0008 | Unfree packages opt-in           | `nix/flake.nix`, `.assets/lib/nx.sh`                      | [0008](0008-unfree-opt-in.md)       |
