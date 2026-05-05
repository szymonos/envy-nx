# Terraform utilities - tfswitch downloads the terraform binary to ~/.local/bin/.
# nix provides tfswitch (the version manager) and tflint (linter); terraform
# itself is installed by tfswitch into ~/.local/bin/ at post-install time.
# `# bins:` lists tfswitch + tflint strict (in ~/.nix-profile/bin/) plus
# terraform with `%` marker (on PATH via ~/.local/bin/ but not in nix-profile).
# bins: tfswitch tflint terraform%
{ pkgs }: with pkgs; [
  tfswitch
  tflint
]
