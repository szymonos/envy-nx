#!/usr/bin/env bats
# Unit tests for tests/hooks/check_curl_tls.py - the hook that requires
# `--proto '=https' --tlsv1.2` on every executing curl/wget fetch.
# Most cases here are false-positive guards: of the raw curl/wget tokens in
# this repo only a minority are actual fetches.
# shellcheck disable=SC2154
bats_require_minimum_version 1.5.0

REPO_SRC="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

setup() {
  FIXTURE="$(mktemp -d)"
  mkdir -p "$FIXTURE/.assets/provision" "$FIXTURE/.assets/lib" "$FIXTURE/nix/lib"
  cd "$REPO_SRC" || return 1
}

teardown() {
  rm -rf "$FIXTURE"
}

_fixture() {
  cat >"$FIXTURE/.assets/provision/$1"
}

_run_hook() {
  CHECK_CURL_TLS_ROOT="$FIXTURE" python3 -m tests.hooks.check_curl_tls "$@"
}

@test "clean file: fetch carrying both flags => pass" {
  _fixture clean.sh <<'EOF'
#!/usr/bin/env bash
curl --proto '=https' --tlsv1.2 -sSf -L https://example.invalid/install | sh
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "violating file: bare curl fetch => fail naming the missing flags" {
  _fixture bad.sh <<'EOF'
#!/usr/bin/env bash
ver="$(curl -fsSL "$metadata_uri" | jq -r '.version')"
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *".assets/provision/bad.sh:2:"* ]]
  [[ "$output" == *"--proto '=https'"* ]]
  [[ "$output" == *"--tlsv1.2"* ]]
}

@test "suppressed file: # tls-probe-ok with a reason => pass" {
  _fixture probe.sh <<'EOF'
#!/usr/bin/env bash
curl -ksS "$1" >/dev/null 2>&1 # tls-probe-ok: -k is load-bearing here
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "suppression without a reason is rejected" {
  _fixture noreason.sh <<'EOF'
#!/usr/bin/env bash
curl -ksS "$1" >/dev/null 2>&1 # tls-probe-ok:
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"carries no reason text"* ]]
}

@test "tricky parse: a commented curl example is not a violation" {
  # Mirrors .assets/lib/helpers.sh - a doc comment that reads exactly like a
  # violating fetch. Any matcher that does not strip `#` comments fails here.
  _fixture commented.sh <<'EOF'
#!/usr/bin/env bash
# Usage (inside any configure script):
#   _io_step "downloading miniforge installer"
#   curl -fsSL ... | bash
_io_step() { printf '%s\n' "$*" >&2; }
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "the : '...' runnable-examples block is not scanned" {
  _fixture examples.sh <<'EOF'
#!/usr/bin/env bash
: '
curl -fsSL https://example.invalid/x | bash
'
echo done
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "a curl string passed to an output helper is not a fetch" {
  _fixture hint.sh <<'EOF'
#!/usr/bin/env bash
err "  curl -sSf -L https://install.determinate.systems/nix | sh"
printf 'run: curl -fsSL https://example.invalid | bash\n'
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "package names and existence probes are not fetches" {
  _fixture pkg.sh <<'EOF'
#!/usr/bin/env bash
apk add --no-cache ca-certificates curl tar
apt-get install -y -qq build-essential curl gnupg
if ! command -v curl >/dev/null 2>&1; then exit 1; fi
elif_placeholder() { ! type curl &>/dev/null; }
for cmd in curl jq tar; do echo "$cmd"; done
has_system_cmd curl || exit 1
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "alias definitions are not fetches" {
  cat >"$FIXTURE/.assets/lib/aliases.sh" <<'EOF'
#!/usr/bin/env bash
alias wget='wget -c'
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "flags held in a variable are resolved, not flagged" {
  # .assets/provision/install_nix.sh shape: the flags are invisible to a line
  # matcher because they live in $curl_flags, set one line earlier.
  _fixture viavar.sh <<'EOF'
#!/usr/bin/env bash
curl_flags="--proto '=https' --proto-redir '=https' --tlsv1.2 -sSf -L"
su - "$SUDO_USER" -c "curl $curl_flags https://nixos.org/nix/install | sh -s -- --no-daemon"
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "a variable holding flags without --tlsv1.2 does not rescue the call" {
  _fixture viabadvar.sh <<'EOF'
#!/usr/bin/env bash
curl_flags="-sSf -L"
su - "$SUDO_USER" -c "curl $curl_flags https://nixos.org/nix/install | sh"
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"viabadvar.sh:3:"* ]]
}

@test "a variable carrying -k alongside the required flags is still rejected" {
  # The -k lives on the assignment line, so the check on the invocation line
  # cannot see it; the variable must not be treated as compliant.
  _fixture viainsecurevar.sh <<'EOF'
#!/usr/bin/env bash
curl_flags="--proto '=https' --tlsv1.2 --insecure -sSf -L"
curl $curl_flags https://example.invalid/install | sh
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"viainsecurevar.sh:3:"* ]]
  [[ "$output" == *"insecure"* ]]
}

@test "backslash continuations are judged as one command" {
  _fixture wrapped.sh <<'EOF'
#!/usr/bin/env bash
curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
  https://download.example.invalid/gpg -o /etc/apt/keyrings/x.asc
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "--proto-redir alone does not satisfy the --proto requirement" {
  _fixture redironly.sh <<'EOF'
#!/usr/bin/env bash
curl --proto-redir '=https' --tlsv1.2 -fsSL https://example.invalid/x -o /tmp/x
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"--proto '=https'"* ]]
}

@test "wget needs --secure-protocol, not --proto" {
  _fixture w.sh <<'EOF'
#!/usr/bin/env bash
wget -q --spider https://example.invalid/x
wget --secure-protocol=TLSv1_2 -q https://example.invalid/y
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"--secure-protocol=TLSv1_2"* ]]
  [[ "${#lines[@]}" -gt 0 ]]
  # exactly one offending line reported (the second wget is compliant)
  [[ "$(printf '%s\n' "$output" | grep -c 'w\.sh:')" -eq 1 ]]
}

@test "indirect fetches through download_file are not flagged" {
  _fixture indirect.sh <<'EOF'
#!/usr/bin/env bash
download_file --uri "https://cli.github.com/packages/x.gpg" --target_dir "$TMP_DIR"
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "files outside the scoped dirs are ignored" {
  mkdir -p "$FIXTURE/wsl"
  cat >"$FIXTURE/wsl/host.sh" <<'EOF'
#!/usr/bin/env bash
curl -fsSL https://example.invalid/x
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "the repository itself passes the hook" {
  run python3 -m tests.hooks.check_curl_tls
  [[ "$status" -eq 0 ]]
}

# --- regression: bypasses found by the 1.19.0 PR review ---------------------
# Each of these passed the hook before the fix. They are the ways a future
# unguarded or outright insecure fetch could slip past the gate, so they are
# pinned individually rather than folded into one case.

@test "regression: --proto with a non-https value is rejected" {
  _fixture protovalue.sh <<'EOF'
#!/usr/bin/env bash
curl --proto '=http' --tlsv1.2 -fsSL http://example.invalid/x -o /tmp/x
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *protovalue.sh* ]]
}

@test "regression: --proto all does not satisfy the requirement" {
  _fixture protoall.sh <<'EOF'
#!/usr/bin/env bash
curl --proto all --tlsv1.2 -fsSL https://example.invalid/x -o /tmp/x
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
}

@test "regression: an option-bearing wrapper does not hide the fetch" {
  _fixture wrapperopts.sh <<'EOF'
#!/usr/bin/env bash
sudo -u "$user" curl -fsSL https://example.invalid/x -o /tmp/x
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *wrapperopts.sh* ]]
}

@test "regression: a fetch inside an output helper's command substitution is seen" {
  _fixture cmdsubst.sh <<'EOF'
#!/usr/bin/env bash
info "$(curl -sS https://example.invalid/version)"
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *cmdsubst.sh* ]]
}

@test "regression: -k is rejected even alongside the required flags" {
  _fixture insecure.sh <<'EOF'
#!/usr/bin/env bash
curl --proto '=https' --tlsv1.2 -k -fsSL https://example.invalid/x -o /tmp/x
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *insecure* ]]
}

@test "regression: --insecure long form is rejected too" {
  _fixture insecurelong.sh <<'EOF'
#!/usr/bin/env bash
curl --proto '=https' --tlsv1.2 --insecure -fsSL https://example.invalid/x -o /tmp/x
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
}

@test "an intentional -k probe still passes when suppressed" {
  _fixture probe.sh <<'EOF'
#!/usr/bin/env bash
_probe() { curl -ksS "$1" >/dev/null 2>&1; } # tls-probe-ok: -k distinguishes cert-rejected from unreachable
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "a plain output-helper message with no command substitution still passes" {
  _fixture plainmsg.sh <<'EOF'
#!/usr/bin/env bash
err "  curl --proto '=https' --tlsv1.2 -sSf -L https://example.invalid/nix | sh"
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

# --- regression: bypasses found reviewing the fixes above -------------------

@test "regression: a --proto protocol list containing http is rejected" {
  _fixture protolist.sh <<'EOF'
#!/usr/bin/env bash
curl --proto '=https,http' --tlsv1.2 -fsSL https://example.invalid/x
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
}

@test "regression: command -- curl executes and is checked" {
  _fixture commanddash.sh <<'EOF'
#!/usr/bin/env bash
command -- curl -fsSL https://example.invalid/x -o /tmp/x
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *commanddash.sh* ]]
}

@test "a single-quoted \$( in an output helper is literal, not a fetch" {
  _fixture singlequoted.sh <<'EOF'
#!/usr/bin/env bash
err 'run this yourself: $(curl --proto) example text'
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "regression: a bare VAR=value prefix does not hide the fetch" {
  _fixture assignprefix.sh <<'EOF'
#!/usr/bin/env bash
DEBIAN_FRONTEND=noninteractive curl -fsSL https://example.invalid/x -o /tmp/x
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *assignprefix.sh* ]]
}
