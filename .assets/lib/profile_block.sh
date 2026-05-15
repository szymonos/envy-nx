# Managed-block helper for shell rc files.
# Compatible with bash 3.2 and BSD sed (macOS).
#
# Usage:
#   source .assets/lib/profile_block.sh
#   manage_block <rc-file> <marker> <action> [<content-file>]
#
#   action = upsert  -> replace the block (or insert if absent) with content-file
#   action = remove  -> delete the block; no-op if absent
#   action = inspect -> print start and end line numbers; exits 0 if present, 1 if absent
#
# Marker format (written into the rc file):
#   # >>> <marker> >>>
#   ... block content ...
#   # <<< <marker> <<<
#
# Guarantees:
#   - Atomic write via tmp file + mv; rc is never half-written.
#   - If the block appears more than once, all occurrences are replaced/removed
#     with a warning message to stderr.
#   - rc file is created empty if it does not exist.
#   - File mode is preserved via cp + mv pattern.
#   - Works with BSD sed (no -i ''; uses tmp file instead).

function _pb_begin_tag() { printf '# >>> %s >>>' "$1"; }
function _pb_end_tag() { printf '# <<< %s <<<' "$1"; }

# _pb_count_occurrences <rc-file> <marker>
# prints the number of begin-tag lines found
function _pb_count_occurrences() {
  local rc="$1" marker="$2"
  local tag
  tag="$(_pb_begin_tag "$marker")"
  # grep -c returns 0 when no match on some implementations; guard with || true
  grep -cF "$tag" "$rc" 2>/dev/null || true
}

# manage_block <rc-file> <marker> <action> [<content-file>]
function manage_block() {
  local rc="$1" marker="$2" action="$3" content_file="${4:-}"

  # ensure rc exists
  [ -f "$rc" ] || touch "$rc"

  local begin_tag end_tag
  begin_tag="$(_pb_begin_tag "$marker")"
  end_tag="$(_pb_end_tag "$marker")"

  case "$action" in
  inspect)
    local start_line end_line
    start_line="$(grep -nF "$begin_tag" "$rc" 2>/dev/null | head -1 | cut -d: -f1)"
    end_line="$(grep -nF "$end_tag" "$rc" 2>/dev/null | head -1 | cut -d: -f1)"
    if [ -z "$start_line" ] || [ -z "$end_line" ]; then
      return 1
    fi
    printf '%s %s\n' "$start_line" "$end_line"
    return 0
    ;;

  remove)
    local count
    count="$(_pb_count_occurrences "$rc" "$marker")"
    if [ "$count" -eq 0 ]; then
      return 0
    fi
    if [ "$count" -gt 1 ]; then
      printf '\e[33mwarning: found %s occurrences of managed block "%s" in %s; removing all\e[0m\n' \
        "$count" "$marker" "$rc" >&2
    fi
    local tmp
    tmp="$(mktemp)"
    awk -v begin="$begin_tag" -v end="$end_tag" '
      $0 == begin { skip=1; next }
      skip && $0 == end { skip=0; next }
      !skip { print }
    ' "$rc" | _pb_normalize_trailing >"$tmp"
    command mv -f "$tmp" "$rc"
    return 0
    ;;

  upsert)
    [ -z "$content_file" ] && {
      printf '\e[31merror: manage_block upsert requires a content file\e[0m\n' >&2
      return 1
    }
    [ -f "$content_file" ] || {
      printf '\e[31merror: content file not found: %s\e[0m\n' "$content_file" >&2
      return 1
    }

    local count
    count="$(_pb_count_occurrences "$rc" "$marker")"
    if [ "$count" -gt 1 ]; then
      printf '\e[33mwarning: found %s occurrences of managed block "%s" in %s; replacing all with one\e[0m\n' \
        "$count" "$marker" "$rc" >&2
    fi

    local tmp new_block
    tmp="$(mktemp)"

    # Build the block string we will insert
    new_block="$(
      printf '%s\n' "$begin_tag"
      cat "$content_file"
      printf '%s\n' "$end_tag"
    )"

    if [ "$count" -eq 0 ]; then
      # First insertion - backup before modifying
      cp -p "$rc" "${rc}.nixenv-backup-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
      # Append: ensure blank line separator before the block
      {
        if [ -s "$rc" ]; then
          cat "$rc"
          printf '\n'
        fi
        printf '%s\n' "$new_block"
      } | _pb_normalize_trailing >"$tmp"
    else
      # Replace: use awk to substitute first occurrence, delete rest.
      # The replacement block is multi-line; passing it via `-v` would fail
      # on POSIX/BSD awk (macOS default) with "newline in string at source
      # line 1" - awk would emit nothing, the pipeline would still exit 0
      # (no pipefail), and `mv -f $tmp $rc` would truncate the rc to empty.
      # Use ENVIRON[] which both BSD and GNU awk accept for any string
      # value including embedded newlines.
      NEW_BLOCK="$new_block" awk -v begin="$begin_tag" -v end="$end_tag" '
        BEGIN { done=0; skip=0; replacement=ENVIRON["NEW_BLOCK"] }
        $0 == begin {
          if (!done) { print replacement; done=1 }
          skip=1; next
        }
        skip && $0 == end { skip=0; next }
        !skip { print }
      ' "$rc" | _pb_normalize_trailing >"$tmp"
      # Defense-in-depth: empty-output guard. If the source rc had content
      # but the staged tmp is empty, awk produced nothing - refuse the
      # overwrite. Catches the v1.10.2 multi-line `-v` wipe shape (BSD awk
      # emits zero bytes on parse failure) and any future portability bug
      # that fails the same way. PIPESTATUS-based exit-code capture was
      # tried earlier but slowed bats parallel runs by 25% (an extra
      # mktemp + two wc invocations per upsert pushed test_nx_doctor over
      # the 60s timeout); the empty-output check covers the same bug shape
      # at zero per-call overhead.
      if [ -s "$rc" ] && [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        printf '\e[31merror: manage_block: refusing to overwrite %s - awk produced empty output (source bytes=%s); file left unchanged\e[0m\n' \
          "$rc" "$(wc -c <"$rc" | tr -d ' ')" >&2
        return 1
      fi
    fi

    command mv -f "$tmp" "$rc"
    return 0
    ;;

  *)
    printf '\e[31merror: manage_block: unknown action "%s"\e[0m\n' "$action" >&2
    return 1
    ;;
  esac
}

# _pb_normalize_trailing (stdin filter)
# Strips consecutive trailing blank lines, ensures exactly one trailing newline.
function _pb_normalize_trailing() {
  awk '
    /^[[:space:]]*$/ { blank++; next }
    { for (i=0; i<blank; i++) print ""; blank=0; print }
  '
}
