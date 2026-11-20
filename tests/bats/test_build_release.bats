#!/usr/bin/env bats
# Unit tests for .assets/tools/build_release.sh - the tarball must carry every
# .assets/ folder that shipped code calls.
bats_require_minimum_version 1.5.0

REPO_SRC="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

setup_file() {
  export OUT_DIR="$BATS_FILE_TMPDIR/dist"
  VERSION=0.0.0-test "$REPO_SRC/.assets/tools/build_release.sh" >/dev/null
  tar -tzf "$OUT_DIR/envy-nx-0.0.0-test.tar.gz" >"$BATS_FILE_TMPDIR/listing"
}

@test "tarball ships every .assets folder shipped code references" {
  cd "$REPO_SRC"
  local refs dir missing=""
  # certs/ holds the user's own certificates and is gitignored, never shipped.
  refs="$(grep -rhoE '\.assets/[A-Za-z_]+/' nix modules wsl \
    .assets/check .assets/config .assets/fix .assets/lib .assets/provision .assets/scripts .assets/setup |
    sort -u | grep -v '^\.assets/certs/$')"
  [ -n "$refs" ]
  for dir in $refs; do
    grep -q "^envy-nx-0.0.0-test/$dir" "$BATS_FILE_TMPDIR/listing" || missing="$missing $dir"
  done
  [ -z "$missing" ] || {
    echo "missing from tarball:$missing"
    return 1
  }
}
