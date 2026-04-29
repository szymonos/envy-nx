#!/usr/bin/env bats
# Unit tests for .assets/lib/helpers.sh
# shellcheck disable=SC2034,SC2154
bats_require_minimum_version 1.5.0

setup() {
  # shellcheck source=../../.assets/lib/helpers.sh
  source "$BATS_TEST_DIRNAME/../../.assets/lib/helpers.sh"
}

# =============================================================================
# download_file - parameter validation (no network)
# =============================================================================

@test "download_file fails when uri is missing" {
  run ! download_file --target_dir /tmp
  [[ "$output" == *"uri"*"required"* ]]
}

@test "download_file fails when curl is not available" {
  # shadow curl with a function that doesn't exist
  type() {
    [[ "$1" != "curl" ]] && command type "$@"
    return 1
  }
  run ! download_file --uri "https://example.com/file.tar.gz"
  [[ "$output" == *"curl"*"required"* ]]
}

# =============================================================================
# gh_login_user - parameter validation (no network / no sudo)
# =============================================================================

@test "gh_login_user fails when gh CLI is not installed" {
  [ -x /usr/bin/gh ] && skip "gh CLI is installed on this host"
  run ! gh_login_user
  [[ "$output" == *"gh"*"required"*"not installed"* ]]
}

@test "gh_login_user fails for non-existent user" {
  [ ! -x /usr/bin/gh ] && skip "gh CLI is not installed"
  run ! gh_login_user -u "no_such_user_$$"
  [[ "$output" == *"does not exist"* ]]
}
