# Node.js - node itself is managed by fnm, not nix.
# nix installs the version manager (fnm); fnm owns the runtime in
# ~/.local/share/fnm/node-versions/. Mirrors the python.nix pattern
# (uv installs Python). Lets `npm install -g <pkg>` succeed (the nix
# store is read-only) and per-project `.nvmrc` switching work.
# `# bins:` lists fnm strict (in ~/.nix-profile/bin/) plus node/npm with
# `%` markers - those are on PATH via fnm's shell init but not in nix-profile.
# bins: fnm node% npm%
{ pkgs }: with pkgs; [
  fnm
]
