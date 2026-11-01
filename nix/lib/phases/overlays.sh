# phase: overlays
# Overlay subscriptions (decision 0015). Each line of $ENV_DIR/overlays.list,
# `<name> <overlay> <ref|-> <repo>`, subscribes to overlays/<overlay>/ of a
# repository. Setup clones a remote repository, or reads a local folder as it is,
# copies what the build can use into $ENV_DIR/overlays/, and records every
# subscribed scope file as an overlay entry with origin `sub`.
#
# Reads:  ENV_DIR, SCRIPT_ROOT, overlay_args, unattended, overlay_entries, OVERLAY_DIR
# Writes: overlay_entries, OVERLAY_DIR, OVERLAY_HOOK_DIRS, $ENV_DIR/overlays.list,
#         $ENV_DIR/overlays/
# shellcheck disable=SC2154  # overlay_args, unattended - set by phase_bootstrap_parse_args
#
# Only `*.nix` files and the subscribed overlays' shell_cfg/ are copied. Hooks
# run only from a local folder, which the machine owner placed there: its
# overlay folders go in OVERLAY_HOOK_DIRS, never a copy of a remote repository.

# Prints the physical path of $1: a chain of links followed, and every
# symlinked parent folder resolved.
_overlays_resolve() {
  local _p="$1" _l _n=0 _d
  while [ -L "$_p" ]; do
    _n=$((_n + 1))
    [ "$_n" -le 40 ] || return 1
    _l="$(readlink "$_p")"
    case "$_l" in
    /*) _p="$_l" ;;
    *) _p="$(dirname "$_p")/$_l" ;;
    esac
  done
  # -P: a logical cd would fold `links/..` before the symlink is resolved
  _d="$(cd -P "$(dirname "$_p")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$_d" "$(basename "$_p")"
}

# Prints the file to copy for $2, found in source $3 whose physical path is $1.
# Its physical path must stay inside the source and out of .git, whether a link
# or a symlinked folder leads there: anything copied lands in the
# world-readable nix store.
_overlays_source() {
  local _t _rel="${2#"$3"/}"
  if ! _t="$(_overlays_resolve "$2")" || [ ! -f "$_t" ]; then
    warn "  $_rel: broken symlink - skipped"
    return 1
  fi
  case "$_t" in
  "$1"/.git/* | "$1"/*/.git/*)
    warn "  $_rel: refused - it resolves into a .git folder"
    return 1
    ;;
  "$1"/*) printf '%s\n' "$_t" ;;
  *)
    warn "  $_rel: refused - the symlink resolves outside the repository ($_t)"
    return 1
    ;;
  esac
}

# Clones or fast-forwards one repository and prints what came in.
_overlays_fetch() {
  local _label="$1" _url="$2" _ref="$3" _clone="$4" _old _new
  if [ ! -d "$_clone/.git" ]; then
    info "overlay $_label: cloning"
    rm -rf "$_clone"
    _io_git clone --quiet ${_ref:+--branch "$_ref"} -- "$_url" "$_clone" </dev/null || return 1
    return 0
  fi
  _old="$(_io_git -C "$_clone" rev-parse HEAD)" || return 1
  _io_git -C "$_clone" fetch --quiet --tags --force origin </dev/null || return 1
  if _io_git -C "$_clone" symbolic-ref -q HEAD >/dev/null; then
    _io_git -C "$_clone" merge --ff-only --quiet '@{upstream}' >/dev/null 2>&1 || {
      warn "overlay $_label: upstream history is not a fast-forward of the local clone"
      return 1
    }
  else
    # a pinned tag moves forward only, like a followed branch
    _io_git -C "$_clone" merge-base --is-ancestor HEAD "$_ref^{commit}" 2>/dev/null || {
      warn "overlay $_label: $_ref moved to a commit that does not descend from the current one"
      return 1
    }
    _io_git -C "$_clone" checkout --quiet --detach "$_ref" || return 1
  fi
  _new="$(_io_git -C "$_clone" rev-parse HEAD)" || return 1
  [ "$_old" != "$_new" ] || return 0
  info "overlay $_label: updated ${_old:0:12}..${_new:0:12}"
  _io_git -C "$_clone" log --oneline --max-count=20 "$_old..$_new" || true
  _io_git -C "$_clone" diff --stat "$_old" "$_new" || true
}

# Copies every *.nix file of source $1 into $2, so imports across folders
# resolve. The walk starts at the physical path, so a symlinked local folder
# works. Fails, copying nothing, when part of the source cannot be read: an
# incomplete copy would read as scopes deleted and run their remove steps.
_overlays_copy_nix() {
  local _real _f _src _rel _found
  _real="$(cd -P "$1" && pwd -P)" || return 1
  rm -rf "$2"
  mkdir -p "$2"
  _found="$(mktemp)"
  if ! find "$_real" -name .git -prune -o -name '*.nix' \( -type f -o -type l \) -print >"$_found"; then
    rm -f "$_found"
    warn "overlay source $1 could not be read in full - keeping the previous copy"
    return 1
  fi
  while IFS= read -r _f; do
    _src="$(_overlays_source "$_real" "$_f" "$_real")" || continue
    _rel="${_f#"$_real"/}"
    # checked by hand: the caller's `if !` turns errexit off in here
    if ! { mkdir -p "$2/$(dirname "$_rel")" && cp "$_src" "$2/$_rel"; }; then
      rm -f "$_found"
      warn "overlay source $1: could not copy $_rel - keeping the previous copy"
      return 1
    fi
  done <"$_found"
  rm -f "$_found"
}

# Stages shell_cfg/ of overlay folder $3 from source $2 into the new copy $4. For
# a remote subscription the last run already applied ($6 true), any change
# against the previous copy $5 - files added, changed, or the folder appearing or
# going - is shown in full and needs a yes; without one (or unattended) the
# previous files stay. A new subscription or a new ref skips the question,
# because choosing it was the review, and so does a local folder.
_overlays_copy_shell_cfg() {
  local _name="$1" _sub="/$3/shell_cfg" _real _f _src _ans="" _empty _a _b
  local _new="$4$_sub" _old="$5$_sub"
  if [ -d "$2$_sub" ]; then
    _real="$(cd "$2" && pwd -P)"
    mkdir -p "$_new"
    for _f in "$2$_sub"/*; do
      [ -f "$_f" ] || [ -L "$_f" ] || continue
      case "$(basename "$_f")" in *[!A-Za-z0-9_.-]*) continue ;; esac
      _src="$(_overlays_source "$_real" "$_f" "$2")" || continue
      cp "$_src" "$_new/$(basename "$_f")"
    done
  fi
  [ "$6" = true ] || return 0
  [ -d "$_old" ] || [ -d "$_new" ] || return 0
  _empty="$(mktemp -d)"
  _a="$_old" _b="$_new"
  [ -d "$_a" ] || _a="$_empty"
  [ -d "$_b" ] || _b="$_empty"
  if diff -r "$_a" "$_b" >/dev/null 2>&1; then
    rm -rf "$_empty"
    return 0
  fi
  warn "overlay $_name: shell config changed"
  diff -ruN "$_a" "$_b" || true
  if [ "${unattended:-false}" != true ] && [ -t 0 ]; then
    read -r -p "Apply the shell config change from overlay $_name? [y/N] " _ans || _ans=""
  fi
  case "$_ans" in
  [yY]*) ;;
  *)
    rm -rf "$_new"
    if [ -d "$_old" ]; then
      mkdir -p "$(dirname "$_new")"
      cp -R "$_old" "$_new"
    fi
    warn "overlay $_name: shell config change skipped - run nx setup in a terminal to review it"
    ;;
  esac
  rm -rf "$_empty"
}

# Adds each --overlay address to overlays.list. An address without #<overlay>
# is resolved here, once: a single overlay or `default`, else a picker in a
# terminal, else a refusal listing the names. The same overlay of the same
# repository at another ref replaces its line; anything else under a taken name
# stops. Re-adding a subscription changes nothing and keeps its exclusions.
_overlays_save_args() {
  [ "${#overlay_args[@]}" -gt 0 ] || return 0
  local _list="$ENV_DIR/overlays.list" _a _p _url _ref _name _key _local _listing _names _ov
  local _n _o _r _repo _lines="" _found _tmp _interactive=false _line
  [ -f "$_list" ] && _lines="$(cat "$_list")"
  [ "${unattended:-false}" != true ] && [ -t 0 ] && _interactive=true
  for _a in "${overlay_args[@]}"; do
    _p="$(_nx_ov_parse "$_a")" || {
      _ir_error="invalid --overlay address: $_a"
      err "$_ir_error"
      exit 2
    }
    IFS='|' read -r _url _ref _name _key _local <<<"$_p"
    _listing=""
    if [ -n "$_name" ]; then
      _names="$_name"
    else
      # resolved once: an image passing the same nameless address on every start
      # keeps what the first run picked, even after the repository grows
      _found=""
      while read -r _n _o _r _repo; do
        [ "$_repo" = "$_url" ] && [ "$_r" = "${_ref:--}" ] && _found="$_n"
      done <<<"$_lines"
      if [ -n "$_found" ]; then
        _ov_explicit+="$_found "
        continue
      fi
      if ! _listing="$(_nx_ov_list "$_url" "$_ref" "$_local")" ||
        ! _names="$(_nx_ov_choose "$_listing" false "$_interactive")"; then
        _ir_error="--overlay $_a: no overlay chosen"
        err "$_ir_error - add #<overlay> to the address"
        exit 2
      fi
    fi
    while IFS= read -r _ov; do
      [ -n "$_ov" ] || continue
      _line="$_ov $_ov ${_ref:--} $_url"
      _found=""
      while read -r _n _o _r _repo; do
        [ "$_n" = "$_ov" ] && _found="$_o ${_r:--} $_repo"
      done <<<"$_lines"
      if [ "$_found" = "${_line#* }" ]; then
        _ov_explicit+="$_ov "
        continue
      fi
      # a new subscription must name an overlay the repository has
      if [ -z "$_listing" ] && ! _listing="$(_nx_ov_list "$_url" "$_ref" "$_local")"; then
        _ir_error="--overlay $_a: could not read $_url"
        err "$_ir_error"
        exit 1
      fi
      if ! printf '%s\n' "$_listing" | cut -f 1 | grep -qx -- "$_ov"; then
        _ir_error="--overlay $_a: $_url has no overlay $_ov"
        err "$_ir_error - it has: $(printf '%s\n' "$_listing" | cut -f 1 | tr '\n' ' ')"
        exit 2
      fi
      if [ -n "$_found" ] && [ "${_found%% *} ${_found##* }" != "$_ov $_url" ]; then
        _ir_error="an overlay subscription named '$_ov' already exists ($_found)"
        err "$_ir_error - subscribe with nx overlay add $_url $_ov --as <name>"
        exit 1
      fi
      _lines="$(printf '%s\n' "$_lines" | awk -v n="$_ov" '$1 != n && NF')"
      _lines="${_lines:+$_lines
}$_line"
      _ov_explicit+="$_ov "
      info "overlay $_ov: subscribed to $_url${_ref:+ at $_ref}"
    done <<<"$_names"
  done
  _tmp="$(mktemp "$_list.XXXXXX")"
  printf '%s\n' "$_lines" >"$_tmp" && mv -f "$_tmp" "$_list"
}

phase_overlays_sync() {
  # shellcheck source=../../../.assets/lib/nx_overlay.sh
  source "$SCRIPT_ROOT/.assets/lib/nx_overlay.sh"
  OVERLAY_HOOK_DIRS=""
  # subscriptions named on this command line (--overlay, or nx overlay add via
  # NX_OVERLAY_EXPLICIT) count as reviewed and must resolve (decision 0015 D10)
  _ov_explicit=" ${NX_OVERLAY_EXPLICIT:-} "
  _overlays_save_args
  local _list="$ENV_DIR/overlays.list" _root="$ENV_DIR/overlays" _cache
  _cache="$(_nx_ov_cache_dir)"
  # an unreadable list would read as "every subscription removed"
  if [ -e "$_list" ] && { [ ! -f "$_list" ] || [ ! -r "$_list" ]; }; then
    _ir_error="$_list is not a readable file"
    err "$_ir_error - fix its permissions, or delete it to drop every overlay subscription"
    exit 1
  fi
  if ! grep -q '[^[:space:]]' "$_list" 2>/dev/null; then
    [ -d "$_root" ] && rm -rf "$_root" && info "removed the overlay subscription copies"
    return 0
  fi
  [ "${unattended:-false}" = true ] && export GIT_TERMINAL_PROMPT=0

  # _subs lines: <name>|<url>|overlays/<overlay>|<ref>|<key>|<local>
  local _name _ov _r _repo _p _subs="" _names=" " _keys=" " _url _ref _o _key _local
  while read -r _name _ov _r _repo || [ -n "$_name" ]; do
    case "$_name" in "" | \#*) continue ;; esac
    case "$_name$_ov" in *[!A-Za-z0-9_-]*)
      warn "overlay '$_name' in $_list ignored - names may use only letters, digits, - and _"
      continue
      ;;
    esac
    if [[ "$_names" == *" $_name "* ]]; then
      warn "overlay '$_name' is listed twice in $_list - the first line wins"
      continue
    fi
    [ "$_r" = - ] && _r=""
    _p="$(_nx_ov_parse "$_repo" "$_r")" || {
      warn "overlay $_name: ignored - invalid repository $_repo"
      continue
    }
    IFS='|' read -r _url _ref _o _key _local <<<"$_p"
    _names+="$_name "
    _subs+="$_name|$_url|overlays/$_ov|$_ref|$_key|$_local"$'\n'
  done <"$_list"

  # One clone and one copy per repository and ref, however many overlays come
  # from it. First fetch every clone, then let a subscription whose source could
  # not be read fall back to the copy the last run applied (.applied), then
  # rebuild the copies of what was read.
  local _dir _sname _surl _sdir _sref _skey _slocal _est _fetched=" " _stale=" " _src
  mkdir -p "$_root" "$_cache"
  while IFS='|' read -r _name _url _dir _ref _key _local; do
    [ -n "$_key" ] && [[ "$_keys" != *" $_key "* ]] || continue
    _keys+="$_key "
    # an interrupted swap leaves the previous copy as .old-<key>
    [ -d "$_root/$_key" ] || [ ! -d "$_root/.old-$_key" ] || mv "$_root/.old-$_key" "$_root/$_key"
    if [ "$_local" = true ]; then
      if [ -d "$_url" ] && [ -r "$_url" ]; then
        _fetched+="$_key "
      else
        warn "overlay folder $_url is missing or unreadable - keeping the previous copy"
      fi
      continue
    fi
    if ! command -v git >/dev/null 2>&1; then
      warn "git not found - overlay $_url is not updated this run"
      _stale+="$_key "
    elif ! _overlays_fetch "$_url${_ref:+ at $_ref}" "$_url" "$_ref" "$_cache/$_key" </dev/null; then
      _stale+="$_key "
      [ -d "$_cache/$_key/.git" ] && warn "overlay $_url: update failed - building from the previous clone"
    fi
    if [ -d "$_cache/$_key/.git" ]; then
      _fetched+="$_key "
    else
      warn "overlay $_url${_ref:+ at $_ref}: could not fetch - keeping the previous copy"
    fi
  done <<<"$_subs"

  # a subscription named on this command line must resolve: setup stops before any
  # scope changes rather than start a workspace without its tools
  local _xsrc
  while IFS='|' read -r _name _url _dir _ref _key _local; do
    [ -n "$_name" ] && [[ "$_ov_explicit" == *" $_name "* ]] || continue
    # a cached clone whose update failed is stale: fine for a saved subscription,
    # not for one the command line asked for
    if [[ "$_fetched" != *" $_key "* || "$_stale" == *" $_key "* ]]; then
      _ir_error="overlay $_name: could not read $_url${_ref:+ at $_ref}"
      err "$_ir_error"
      exit 1
    fi
    _xsrc="$_cache/$_key"
    [ "$_local" = true ] && _xsrc="$_url"
    if [ ! -d "$_xsrc/$_dir" ]; then
      _ir_error="overlay $_name: $_url has no $_dir"
      err "$_ir_error"
      exit 2
    fi
  done <<<"$_subs"

  local _eff="" _an _ak _ad
  while IFS='|' read -r _name _url _dir _ref _key _local; do
    [ -n "$_name" ] || continue
    if [[ "$_fetched" != *" $_key "* ]] && [ ! -d "$_root/$_key" ] && [ -f "$_root/.applied" ]; then
      while IFS='|' read -r _an _ak _ad; do
        [ "$_an" = "$_name" ] && [ "$_ak" != "$_key" ] && [ -d "$_root/$_ak" ] || continue
        warn "overlay $_name: keeping the previous copy until ${_url}${_ref:+ at $_ref} can be read"
        _key="$_ak" _dir="$_ad"
        _keys+="$_key "
        break
      done <"$_root/.applied"
    fi
    _eff+="$_name|$_url|$_dir|$_ref|$_key|$_local"$'\n'
  done <<<"$_subs"
  _subs="$_eff"

  # the lists come in on fd 3 and 4, so the shell config prompt reads the terminal
  local _built=" "
  while IFS='|' read -r _name _url _dir _ref _key _local <&3; do
    [[ "$_fetched" == *" $_key "* && "$_built" != *" $_key "* ]] || continue
    _built+="$_key "
    _src="$_cache/$_key"
    [ "$_local" = true ] && _src="$_url"
    if ! _overlays_copy_nix "$_src" "$_root/.new-$_key"; then
      rm -rf "$_root/.new-$_key"
      while IFS='|' read -r _sname _surl _sdir _sref _skey _slocal <&4; do
        [ "$_skey" = "$_key" ] && [[ "$_ov_explicit" == *" $_sname "* ]] || continue
        _ir_error="overlay $_sname: could not copy $_surl"
        err "$_ir_error"
        exit 1
      done 4<<<"$_subs"
      continue
    fi
    while IFS='|' read -r _sname _surl _sdir _sref _skey _slocal <&4; do
      [ "$_skey" = "$_key" ] || continue
      # an overlay with no scope file yet still exists (its hooks, shell_cfg)
      [ -d "$_src/$_sdir" ] && mkdir -p "$_root/.new-$_key/$_sdir"
      # asks only for a remote subscription refreshed from the saved list
      _est=false
      [ "$_slocal" != true ] && [[ "$_ov_explicit" != *" $_sname "* ]] &&
        grep -qxF "$_sdir" "$_root/$_key/.subscriptions" 2>/dev/null && _est=true
      _overlays_copy_shell_cfg "$_sname" "$_src" "$_sdir" "$_root/.new-$_key" "$_root/$_key" "$_est"
      printf '%s\n' "$_sdir" >>"$_root/.new-$_key/.subscriptions"
    done 4<<<"$_subs"
    rm -rf "$_root/.old-$_key"
    [ ! -d "$_root/$_key" ] || mv "$_root/$_key" "$_root/.old-$_key"
    mv "$_root/.new-$_key" "$_root/$_key"
    rm -rf "$_root/.old-$_key"
  done 3<<<"$_subs"

  # overlay entries, the flake's id-to-file index, and the folders profiles and
  # hooks read
  local _exclude=" " _l _folder _f _scope _id _index="" _dirs="" _tmp _applied=""
  if [ -f "$ENV_DIR/overlays.exclude" ]; then
    while read -r _l || [ -n "$_l" ]; do [ -n "$_l" ] && _exclude+="$_l "; done <"$ENV_DIR/overlays.exclude"
  fi
  while IFS='|' read -r _name _url _dir _ref _key _local; do
    [ -n "$_name" ] || continue
    _folder="$_root/$_key/$_dir"
    if [ ! -d "$_root/$_key" ]; then
      continue
    elif [ ! -d "$_folder" ]; then
      warn "overlay $_name: no $_dir in $_url"
      continue
    fi
    info "overlay subscription: $_name"
    _applied+="$_name|$_key|$_dir"$'\n'
    _dirs="${_dirs:+$_dirs:}$_folder"
    if [ "$_local" = true ] && [ -d "$_url/$_dir/hooks/post-setup.d" ]; then
      OVERLAY_HOOK_DIRS="${OVERLAY_HOOK_DIRS:+$OVERLAY_HOOK_DIRS:}$_url/$_dir"
    fi
    for _f in "$_folder/scopes"/*.nix; do
      [ -f "$_f" ] || continue
      _scope="$(basename "$_f" .nix)"
      case "$_scope" in *[!A-Za-z0-9_-]*)
        warn "  $_f ignored - scope file names may use only letters, digits, - and _"
        continue
        ;;
      esac
      _id="$_name/$_scope"
      _index+="  \"$_id\" = ./. + \"/${_f#"$_root"/}\";"$'\n'
      if [[ "$_exclude" == *" $_id "* ]]; then
        info "  $_id excluded (nx scope add $_id brings it back)"
        continue
      fi
      overlay_entries+="sub $_id $_f"$'\n'
      _overlay_add_header_entries sub "$_f"
    done
  done <<<"$_subs"
  # A standard scope opted out by name (`nx scope remove <scope>`) leaves the
  # overlays' header entries: its remove step runs once, and later runs no longer
  # merge it back from the header. A personal header still names it.
  for _l in $_exclude; do
    case "$_l" in */*) continue ;; esac
    overlay_entries="$(printf '%s' "${overlay_entries:-}" | awk -v s="$_l" '!($1 == "sub" && $2 == s)')"$'\n'
  done
  _tmp="$(mktemp "$_root/index.nix.XXXXXX")"
  printf '# Generated by setup.sh - overlay scope ids and their files.\n{\n%s}\n' "$_index" >"$_tmp"
  if [ -f "$_root/index.nix" ] && cmp -s "$_tmp" "$_root/index.nix"; then
    rm -f "$_tmp"
  else
    mv -f "$_tmp" "$_root/index.nix"
  fi
  _tmp="$(mktemp "$_root/.applied.XXXXXX")"
  printf '%s' "$_applied" >"$_tmp" && mv -f "$_tmp" "$_root/.applied"
  export OVERLAY_HOOK_DIRS

  # every applied overlay joins OVERLAY_DIR before the personal scopes folder:
  # profiles.sh copies its shell_cfg (the personal file wins on a name clash), and
  # scopes.sh skips system detection when an overlay describes the machine
  if [ -n "$_dirs" ]; then
    local _tail=""
    if [ "${OVERLAY_DIR%"$ENV_DIR/local"}" != "${OVERLAY_DIR:-}" ]; then
      _tail="$ENV_DIR/local"
      OVERLAY_DIR="${OVERLAY_DIR%"$ENV_DIR/local"}"
      OVERLAY_DIR="${OVERLAY_DIR%:}"
    fi
    OVERLAY_DIR="${OVERLAY_DIR:+$OVERLAY_DIR:}$_dirs${_tail:+:$_tail}"
    export OVERLAY_DIR
  fi

  local _d
  for _d in "$_root"/* "$_cache"/*; do
    [ -d "$_d" ] || continue
    [[ "$_keys" == *" $(basename "$_d") "* ]] || rm -rf "$_d"
  done
  return 0
}
