# Miniforge (conda) - installed via installer script, not nix.
# This scope only triggers configure/conda.sh.
# `# bins: (external-installer)` is a sentinel telling nx doctor to skip
# binary auditing for this scope: conda lives at ~/miniforge3/bin/conda,
# not in ~/.nix-profile/bin/, so the standard nix-profile check would
# always fire a false-positive failure. The validate-scopes hook only
# requires `# bins:` to be non-empty, so the sentinel satisfies it.
# bins: (external-installer)
{ pkgs }: [ ]
