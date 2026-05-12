# Google Cloud CLI - installed via the official tarball into
# $HOME/google-cloud-sdk (see nix/configure/gcloud.sh and
# .assets/provision/install_gcloud.sh). Nix's google-cloud-sdk writes the
# "managed by external package manager" marker which blocks
# `gcloud components install`, breaking gke-gcloud-auth-plugin (needed for
# GKE kubectl auth). The tarball install behaves like a plain user-space
# tool with `gcloud components install` working normally.
# `# bins: (external-installer)` is a sentinel telling nx doctor to skip
# binary auditing for this scope: gcloud lives at $HOME/google-cloud-sdk/bin/,
# not in ~/.nix-profile/bin/, so the standard nix-profile check would always
# fire a false-positive failure.
# bins: (external-installer)
{ pkgs }: [ ]
