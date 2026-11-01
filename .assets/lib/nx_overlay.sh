: '
# Sourced, not run directly. After `source .assets/lib/nx_overlay.sh`:
_nx_ov_parse "github:szymonos/nix-overlay/v2#k8s"
_nx_ov_list "https://github.com/szymonos/nix-overlay.git" "" false
_nx_ov_cache_dir
'

# Overlay subscriptions (decision 0015), shared by `nx overlay`, `nx doctor` and
# the overlays setup phase. Sourced into interactive bash and zsh, and on the nix
# setup path, so bash 3.2 and zsh both apply.
#
# A repository holds its overlays as overlays/<name>/ folders, each with
# scopes/*.nix, an optional shell_cfg/ and an optional README.md whose first line
# describes it. Everything outside overlays/ is shared files.

# Where subscribed repositories are cloned, one folder per repo key.
function _nx_ov_cache_dir() {
  printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/nix-env/overlays"
}

# Parses an overlay address into five `|`-separated fields:
#   <repo url>|<ref>|<overlay>|<repo key>|<local>
# The address is <repo>[#<overlay>], in Nix flake-reference style:
# github:<owner>/<repo>[/<ref>], an https/ssh git URL, or an absolute path to a
# folder, which is copied as it is, git or not (<local> is true). An empty ref is
# the default branch; an empty overlay means "choose" (_nx_ov_choose). The
# separator is not whitespace, so `read` keeps empty fields. $2, when given,
# sets the ref (overlays.list and `--ref` keep it apart from the repository).
function _nx_ov_parse() {
  local addr="$1" base name="" url ref="" repo key local=false
  case "$addr" in
  "" | *[[:space:]]* | *"|"*)
    printf 'invalid overlay address: %s\n' "$addr" >&2
    return 1
    ;;
  esac
  local query="" qref=""
  base="${addr%%#*}"
  [ "$base" != "$addr" ] && name="${addr#*#}"
  case "$name" in
  *[!A-Za-z0-9_-]*)
    printf 'invalid overlay name: %s (letters, digits, - and _)\n' "$name" >&2
    return 1
    ;;
  esac
  # ?ref=<ref> as in Nix git flake refs, for every remote address
  case "$base" in *\?*)
    query="${base#*\?}"
    base="${base%%\?*}"
    case "$query" in
    ref=*) qref="${query#ref=}" ;;
    *)
      printf 'unknown overlay address option: %s (only ref= is accepted)\n' "$query" >&2
      return 1
      ;;
    esac
    case "$qref" in "" | *"&"*)
      printf 'invalid overlay address option: %s\n' "$query" >&2
      return 1
      ;;
    esac
    ;;
  esac
  case "$base" in
  github:*)
    repo="${base#github:}"
    case "$repo" in */*/*)
      ref="${repo#*/*/}"
      repo="${repo%"/$ref"}"
      ;;
    esac
    if [ -n "$ref" ] && [ -n "$qref" ]; then
      printf 'give the ref once, as /<ref> or ?ref=: %s\n' "$addr" >&2
      return 1
    fi
    repo="${repo%.git}"
    case "$repo" in
    */*/* | /* | */ | *[!A-Za-z0-9._/-]* | "") repo="" ;;
    */*) ;;
    *) repo="" ;;
    esac
    if [ -z "$repo" ]; then
      printf 'invalid GitHub address: %s (expected github:<owner>/<repo>[/<ref>])\n' "$base" >&2
      return 1
    fi
    url="https://github.com/$repo.git"
    ;;
  https://* | ssh://* | file://* | *@*:*) url="$base" ;;
  /*)
    url="${base%/}"
    local=true
    # setup joins overlay folders with `:` (OVERLAY_DIR, OVERLAY_HOOK_DIRS)
    case "$url" in *:*)
      printf 'a local overlay folder path cannot contain a colon - symlink it: %s\n' "$url" >&2
      return 1
      ;;
    esac
    ;;
  http://* | git://*)
    printf 'refusing an unencrypted overlay address: %s\n' "$base" >&2
    return 1
    ;;
  *)
    printf 'unsupported overlay address: %s\n' "$base" >&2
    return 1
    ;;
  esac
  [ -n "$qref" ] && ref="$qref"
  [ -n "${2:-}" ] && ref="$2"
  if [ "$local" = true ] && [ -n "$ref" ]; then
    printf 'a local overlay folder takes no ref - it is copied as it is: %s\n' "$base" >&2
    return 1
  fi
  case "$ref" in
  -* | *[!A-Za-z0-9._/+-]* | *..*)
    printf 'invalid overlay ref: %s\n' "$ref" >&2
    return 1
    ;;
  esac
  # the key names the clone and the copy: one per repository and ref, since one
  # checkout cannot follow two refs. The readable part folds characters together
  # (a-b/c and a/b-c), so a checksum of the exact url and ref keeps keys apart.
  key="${url#*://}"
  key="${key#*@}"
  key="${key%.git}"
  key="${key%/}"
  [ -n "$ref" ] && key="$key--$ref"
  key="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '-')"
  key="${key#-}-$(printf '%s|%s' "$url" "$ref" | cksum | cut -d ' ' -f 1)"
  printf '%s|%s|%s|%s|%s\n' "$url" "$ref" "$name" "$key" "$local"
}

# Prints "<name><TAB><description>" for each overlay in folder $1 (a checkout or
# a local overlay repository), sorted by name. Fails with a message when $1 has
# no overlays/ folder.
function _nx_ov_list_dir() {
  local d n desc
  if [ ! -d "$1/overlays" ]; then
    printf 'no overlays/ in this repository: %s\n' "$1" >&2
    return 2
  fi
  find "$1/overlays" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | while IFS= read -r d; do
    n="${d##*/}"
    case "$n" in "" | *[!A-Za-z0-9_-]*) continue ;; esac
    desc=""
    # a symlinked README could print the first line of any file on the machine
    [ -f "$d/README.md" ] && [ ! -L "$d/README.md" ] &&
      desc="$(sed -n '1{s/^#*[[:space:]]*//;p;}' "$d/README.md")"
    printf '%s\t%s\n' "$n" "$desc"
  done
}

# Lists the overlays of repository $1 at ref $2 ($3 true: a local folder) as
# _nx_ov_list_dir does. A remote repository is read from a shallow clone in a
# temporary folder, so listing never touches the subscription clones.
function _nx_ov_list() {
  local tmp rc
  if [ "$3" = true ]; then
    _nx_ov_list_dir "$1"
    return
  fi
  tmp="$(mktemp -d)" || return 1
  # two words spelled out: zsh keeps ${2:+--branch "$2"} as one argument
  if [ -n "$2" ]; then
    set -- "$1" "$2" --branch "$2"
  else
    set -- "$1" "" --single-branch
  fi
  if ! git clone --quiet --depth 1 "$3" ${4:+"$4"} -- "$1" "$tmp/repo" </dev/null; then
    command rm -rf "$tmp"
    printf 'could not fetch %s%s\n' "$1" "${2:+ at $2}" >&2
    return 1
  fi
  _nx_ov_list_dir "$tmp/repo"
  rc=$?
  command rm -rf "$tmp"
  return $rc
}

# Prints the overlay names to install from listing $1 (_nx_ov_list output), one
# per line. $2 true installs every overlay. Otherwise a single overlay, or the
# one named `default`, is chosen; with several and no default, $3 true asks in
# the terminal and anything else refuses, listing the names. A missing name
# never means everything.
function _nx_ov_choose() {
  local listing="$1" n desc i=0 ans pick out=""
  if [ -z "$listing" ]; then
    printf 'the repository has an overlays/ folder but no overlay in it\n' >&2
    return 1
  fi
  if [ "$2" = true ]; then
    printf '%s\n' "$listing" | cut -f 1
    return 0
  fi
  if [ "$(printf '%s\n' "$listing" | wc -l | tr -d ' ')" = 1 ]; then
    printf '%s\n' "$listing" | cut -f 1
    return 0
  fi
  if printf '%s\n' "$listing" | cut -f 1 | command grep -qx default; then
    printf 'default\n'
    return 0
  fi
  if [ "$3" != true ]; then
    printf 'the repository has several overlays and none named default - name the ones to install:\n' >&2
    printf '%s\n' "$listing" | while IFS="$(printf '\t')" read -r n desc; do
      printf '  %s%s\n' "$n" "${desc:+ - $desc}" >&2
    done
    return 1
  fi
  printf 'Overlays in this repository:\n' >&2
  while IFS="$(printf '\t')" read -r n desc; do
    i=$((i + 1))
    printf '  %d) %s%s\n' "$i" "$n" "${desc:+ - $desc}" >&2
  done <<EOF
$listing
EOF
  printf 'Install which? (numbers or names, separated by spaces): ' >&2
  read -r ans || ans=""
  # one pick per line: zsh does not word-split an unquoted $ans
  while IFS= read -r pick; do
    [ -n "$pick" ] || continue
    case "$pick" in
    *[!0-9]*) n="$(printf '%s\n' "$listing" | cut -f 1 | command grep -x -- "$pick")" || n="" ;;
    *) n="$(printf '%s\n' "$listing" | sed -n "${pick}p" | cut -f 1)" ;;
    esac
    if [ -z "$n" ]; then
      printf 'no overlay %s in this repository\n' "$pick" >&2
      return 1
    fi
    out="$out$n
"
  done <<EOF
$(printf '%s\n' "$ans" | tr ' \t' '\n\n')
EOF
  if [ -z "$out" ]; then
    printf 'nothing chosen\n' >&2
    return 1
  fi
  printf '%s' "$out"
}

# Prints the file of scope id $2 in env dir $1. A subscribed id
# (<overlay>/<scope>) is looked up in overlays/index.nix, which setup
# writes; fails when it is not there.
function _nx_ov_scope_file() {
  local rel
  case "$2" in
  */*/* | *[!A-Za-z0-9_/-]*) return 1 ;;
  */*)
    [ -f "$1/overlays/index.nix" ] || return 1
    rel="$(sed -n "s|^  \"$2\" = \./\. + \"\(.*\)\";\$|\1|p" "$1/overlays/index.nix")"
    [ -n "$rel" ] || return 1
    printf '%s\n' "$1/overlays$rel"
    ;;
  *) printf '%s\n' "$1/scopes/$2.nix" ;;
  esac
}
