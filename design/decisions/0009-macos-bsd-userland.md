# macOS keeps its BSD userland (no GNU coreutils by default)

macOS ships a complete BSD userland (`df`, `ls`, `cp`, `find`, `awk`, `date`, ...).
Setup prepends `~/.nix-profile/bin` to PATH, so a GNU tool installed there shadows
the system BSD tool of the same name for every process the user runs. Shipping GNU
`coreutils`/`findutils`/`gawk` in the always-installed base therefore silently
replaced the userland every existing macOS script depends on - and the GNU and BSD
tools differ in flags and output. This contradicted the project's own stance: it
writes nix-path scripts to bash 3.2 + BSD `sed`/`grep` *because macOS is BSD*, then
installed a GNU userland that shadowed those same BSD tools for the user.

**Decision:** On Darwin, `base.nix` does not install `coreutils`, `findutils`, or
`gawk`; macOS keeps its native BSD userland. Off-Darwin (Linux/containers, where the
base may be minimal or BusyBox) they are always installed. Implemented with
`lib.optionals (!stdenv.hostPlatform.isDarwin) [ ... ]`, mirroring `nix/scopes/docker.nix`. GNU
tools stay available on macOS as a conscious opt-in: `nx install coreutils findutils gawk`.

**Consequence:** Project code that runs on macOS must not rely on GNU-only coreutils
behavior (`readlink -f`, `stat -c`, `date -d`, `sort -h`, ...). This already held for
`sed`/`grep` (the bash 3.2 constraint); it now extends to the rest of coreutils.
`check-bash32` does not yet police these idioms, so keep new nix-path code
BSD-portable by review. Removing the trio also unmasked one pre-existing violation
(`readlink -f` in `nix/configure/omp.sh`), now fixed.

**Scope:** `nix/scopes/base.nix`; any nix-path script that runs on macOS.
