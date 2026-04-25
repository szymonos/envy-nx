#!/usr/bin/env bash
: '
# :build release tarball from current HEAD
.assets/tools/build_release.sh
# :build with explicit version
VERSION=1.0.0 .assets/tools/build_release.sh
'
set -euo pipefail

VERSION="${VERSION:-$(git describe --tags --match 'v*' 2>/dev/null || echo "unknown")}"
VERSION="${VERSION#v}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RELEASE_NAME="envy-nx-${VERSION}"
OUT_DIR="$REPO_ROOT/dist"
TARBALL="$OUT_DIR/${RELEASE_NAME}.tar.gz"

mkdir -p "$OUT_DIR"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

# runtime directories
mkdir -p "$STAGING/$RELEASE_NAME/.assets"
for dir in modules nix wsl; do
  if [ -d "$REPO_ROOT/$dir" ]; then
    cp -R "$REPO_ROOT/$dir" "$STAGING/$RELEASE_NAME/$dir"
  fi
done
for dir in check config lib provision scripts setup; do
  if [ -d "$REPO_ROOT/.assets/$dir" ]; then
    cp -R "$REPO_ROOT/.assets/$dir" "$STAGING/$RELEASE_NAME/.assets/$dir"
  fi
done

# root documentation
for file in LICENSE README.md CHANGELOG.md ARCHITECTURE.md CONTRIBUTING.md SUPPORT.md; do
  [ -f "$REPO_ROOT/$file" ] && cp "$REPO_ROOT/$file" "$STAGING/$RELEASE_NAME/"
done

# stamp version
printf '%s\n' "$VERSION" >"$STAGING/$RELEASE_NAME/VERSION"

# remove generated files that may exist in the working tree
rm -f "$STAGING/$RELEASE_NAME/nix/config.nix"
rm -f "$STAGING/$RELEASE_NAME/nix/flake.lock"

# build tarball
tar -czf "$TARBALL" -C "$STAGING" "$RELEASE_NAME"

# generate checksums (shasum works on both macOS and Linux)
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$TARBALL")" >CHECKSUMS.sha256)

printf '\e[32mRelease tarball: %s (%s)\e[0m\n' "$TARBALL" "$(du -h "$TARBALL" | cut -f1)"
printf '\e[32mChecksums:      %s/CHECKSUMS.sha256\e[0m\n' "$OUT_DIR"
