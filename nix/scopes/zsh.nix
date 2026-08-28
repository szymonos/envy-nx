# Zsh plugins
# `zsh%`: the scope installs plugins only - the zsh binary itself comes from the
# system package manager, so it is on PATH but never in ~/.nix-profile/bin.
# bins: zsh%
{ pkgs }: with pkgs; [
  zsh-autosuggestions
  zsh-syntax-highlighting
  zsh-completions
]
