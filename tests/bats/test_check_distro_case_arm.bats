#!/usr/bin/env bats
# Unit tests for tests/hooks/check_distro_case_arm.py - the hook that requires a
# non-empty, last-position `*)` arm on every distro `case` statement.
# shellcheck disable=SC2154
bats_require_minimum_version 1.5.0

# Resolve the source-repo root so the Python module path resolves.
REPO_SRC="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

setup() {
  # Fixture tree mirroring the real layout; CHECK_DISTRO_CASE_ROOT points the
  # hook at it so the bare (whole-tree) scan is what the tests exercise.
  FIXTURE="$(mktemp -d)"
  mkdir -p "$FIXTURE/.assets/provision"
  cd "$REPO_SRC" || return 1
}

teardown() {
  rm -rf "$FIXTURE"
}

# Helper: write a fixture script with the canonical distro-detection line.
_fixture() {
  local name="$1"
  shift
  {
    echo '#!/usr/bin/env bash'
    echo "SYS_ID=\"\$(sed -En '/^ID.*(alpine|arch|fedora|debian|ubuntu|opensuse).*/{s//\\1/;p;q}' /etc/os-release)\""
    cat
  } >"$FIXTURE/.assets/provision/$name"
}

_run_hook() {
  CHECK_DISTRO_CASE_ROOT="$FIXTURE" python3 -m tests.hooks.check_distro_case_arm "$@"
}

@test "clean file: case with a non-empty *) arm as the last arm => pass" {
  _fixture clean.sh <<'EOF'
case $SYS_ID in
alpine)
  apk add --no-cache zsh
  ;;
debian | ubuntu)
  apt-get install -y zsh
  ;;
*)
  printf 'unsupported\n' >&2
  exit 1
  ;;
esac
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "violating file: case with no *) arm => fail with path, line and reason" {
  _fixture bad.sh <<'EOF'
case $SYS_ID in
alpine)
  apk add --no-cache zsh
  ;;
debian | ubuntu)
  apt-get install -y zsh
  ;;
esac
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *".assets/provision/bad.sh:3:"* ]]
  [[ "$output" == *"no \`*)\` default arm"* ]]
}

@test "suppressed file: # distro-case-ok with a reason => pass" {
  _fixture suppressed.sh <<'EOF'
case $SYS_ID in # distro-case-ok: falls through to the probe ladder below
alpine)
  apk add --no-cache curl
  ;;
esac
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "suppression without a reason is rejected" {
  _fixture noreason.sh <<'EOF'
case $SYS_ID in # distro-case-ok:
alpine)
  apk add --no-cache curl
  ;;
esac
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"carries no reason text"* ]]
}

@test "tricky parse: nested case + heredoc body do not produce false arms" {
  # The outer case is compliant. The inner case (over a non-distro subject) and
  # the heredoc body both contain `)` and the word `esac`-adjacent text; a naive
  # line matcher reads them as arms of the outer case and mis-reports.
  _fixture nested.sh <<'EOF'
case $SYS_ID in
debian | ubuntu)
  case "${1:-}" in
  install)
    apt-get install -y zsh
    ;;
  *)
    printf 'unknown subcommand\n' >&2
    ;;
  esac
  cat <<'SOURCES' >/etc/apt/sources.list.d/x.sources
Types: deb
URIs: https://example.invalid/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
SOURCES
  raw_id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"' | head -1)" || true
  printf 'ok %s\n' "$raw_id"
  ;;
*)
  printf 'unsupported\n' >&2
  exit 1
  ;;
esac
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "non-distro case statement is not checked" {
  # Same file detects a distro id, but this case dispatches on \$1 - out of scope.
  _fixture dispatch.sh <<'EOF'
case "${1:-}" in
status) cmd_status ;;
apply) cmd_apply ;;
esac
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "file with no distro detection is out of scope entirely" {
  cat >"$FIXTURE/.assets/provision/other.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
a)
  echo a
  ;;
esac
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "narrowed detection alternation is still in scope" {
  cat >"$FIXTURE/.assets/provision/narrow.sh" <<'EOF'
#!/usr/bin/env bash
SYS_ID="$(sed -En '/^ID.*(fedora|debian|ubuntu|opensuse).*/{s//\1/;p;q}' /etc/os-release)"
case ${SYS_ID:-} in
fedora | opensuse)
  echo rpm
  ;;
esac
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"narrow.sh:3:"* ]]
}

@test "*) arm with an empty body is rejected" {
  _fixture emptyarm.sh <<'EOF'
case $SYS_ID in
alpine)
  apk add --no-cache zsh
  ;;
*) ;;
esac
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"empty body"* ]]
}

@test "*) arm that is not last is rejected" {
  _fixture notlast.sh <<'EOF'
case $SYS_ID in
*)
  printf 'unsupported\n' >&2
  exit 1
  ;;
alpine)
  apk add --no-cache zsh
  ;;
esac
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"not the last arm"* ]]
}

@test "explicit file arguments are honoured (pre-commit invocation)" {
  _fixture bad.sh <<'EOF'
case $SYS_ID in
alpine)
  apk add --no-cache zsh
  ;;
esac
EOF
  _fixture clean.sh <<'EOF'
case $SYS_ID in
*)
  exit 1
  ;;
esac
EOF
  run _run_hook "$FIXTURE/.assets/provision/clean.sh"
  [[ "$status" -eq 0 ]]
  run _run_hook "$FIXTURE/.assets/provision/bad.sh"
  [[ "$status" -eq 1 ]]
}

@test "the repository itself passes the hook" {
  run python3 -m tests.hooks.check_distro_case_arm
  [[ "$status" -eq 0 ]]
}
