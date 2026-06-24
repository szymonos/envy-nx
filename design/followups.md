# Follow-ups

Tracked design ideas that are noted but not scheduled. New items append to the
top with a date stamp; remove an item when it lands or is rejected (capture
the rationale in `docs/decisions.md` if rejected).

## `setup_vscode_macos_env`: set `terminal.integrated.macOptionIsMeta` for PSReadLine keybindings

**Date noted:** 2026-06-24

On macOS the Option key sends a dead-key character (e.g. `å` for `Option+a`) rather than an Escape prefix, so PSReadLine Emacs-mode bindings like `Alt+a` (`SelectCommandArgument`) silently do nothing in the VS Code integrated terminal. The fix is a single VS Code setting:

```json
"terminal.integrated.macOptionIsMeta": true
```

This makes the VS Code terminal send `Esc+<key>` for Option combos, which PSReadLine reads as Meta/Alt — the same behavior iTerm2's "Use Option as Meta key" provides.

**What `setup_vscode_macos_env` / `_vscode_macos_settings_update` would need:**

- Add `terminal.integrated.macOptionIsMeta` to the `need_*` detection block alongside the existing `todo-tree.ripgrep.ripgrep` check.
- Detection: skip if the key already exists (any value) — same pattern as rg.
- Insert: append the key before the root close-brace using the same awk insert block.
- No new ok() message label needed; follow the existing `[ "$need_rg" -eq 1 ] && ok "..."` pattern.
- New bats test cases to add to `tests/bats/test_vscode_macos.bats`:
  - fresh install writes the key.
  - second run is a no-op (existing key, any value, is respected).
  - writes only the key when pwsh and rg are both absent but `$nix_bin` exists (requires relaxing the early-return guard that bails when neither binary is found — or guard the setting separately).

**Gating decision:** write `terminal.integrated.macOptionIsMeta` only when `pwsh` is installed (it's a pwsh UX fix, not a general setting). It is independent of rg availability — the early-exit at line 105 needs to be split so that `need_meta` follows `need_pwsh`, not `need_rg`.

## `nx upgrade --all` - refresh non-Nix tools alongside Nix profile

**Date noted:** 2026-05-12

`nx upgrade` today swaps the nix-env generation. Tools installed outside Nix -
currently `az` (via uv) and `gcloud` (via the official tarball, planned) - are
not refreshed by that path. Each has its own update mechanism:

- `az` -> `uv tool upgrade azure-cli`
- `gcloud` -> `gcloud components update --quiet`

Proposal: an `nx upgrade --all` flag that, after the standard nix-profile
upgrade, iterates through the active scopes and runs each tool's native
upgrade verb. Surface a one-line warning before the run that this can take
several minutes (gcloud component refresh is the slow leg) and require the
flag explicitly so the default `nx upgrade` stays fast and offline-friendly.

Open questions for when this gets picked up:

- Do we model this as a generic "post-upgrade hook per scope" (extensible to
  any future non-Nix tool) or hand-wire the az and gcloud cases?
- Should `--all` also trigger `gh extension upgrade --all` or similar?
- What's the failure mode when a single tool's upgrade fails - abort, warn
  and continue, or aggregate and report at the end?

Defer until at least one user asks for it; the manual `gcloud components
update` and `uv tool upgrade azure-cli` paths are well-understood.
