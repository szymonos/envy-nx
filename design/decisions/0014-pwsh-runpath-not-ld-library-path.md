# pwsh finds its libraries through RUNPATH, not LD_LIBRARY_PATH

nixpkgs ships `bin/pwsh` as a makeWrapper script that prefixes `LD_LIBRARY_PATH`
with the libraries .NET loads by soname at runtime (icu, openssl, curl, pam,
libunwind, util-linux, lttng-ust). Every process pwsh starts inherits that list.
The Determinate `nix` binary links an older glibc than the pinned nixpkgs; with
pwsh's path inherited it loads nixpkgs' libcurl and exits with
``version `GLIBC_2.43' not found``. It recurs whenever the pin moves glibc ahead
of the installed nix.

**Decision:** `nix/flake.nix` overrides `powershell` on Linux (`patchPwsh`):

- `appendRunpaths` adds the package's own `buildInputs` library directories to
  the RUNPATH of every ELF file autoPatchelfHook patches. glibc's `dlopen`
  searches the RUNPATH of the *calling* object, so .NET's native shims
  (`libSystem.Globalization.Native.so`, `...Cryptography.Native.OpenSsl.so`,
  ...) find their libraries with no environment variable.
- `postFixup` rebuilds the wrapper with the telemetry variables only.

The override is keyed on `lib.getName` in the flake, like `collisionLowPrio`
(decision 0010), so scope files stay plain package names for the line-anchored
parser, and `nx install powershell` gets the same build.

Rejected:

- **Keep guarding each launch path.** The profile, `_io_pwsh_nop`, `setup.sh`
  and the Pester runner each cleared the variable, and each new way of starting
  a process was a new gap - the 1.32.0 upstream sync failed through `pwsh -nop`
  running `make lint`.
- **Clear it in a pwsh startup hook.** `-nop` runs no profile, which is the case
  that failed.
- **`runtimeDependencies`.** autoPatchelfHook adds those to executables only;
  the `dlopen` calls come from the shared libraries.
- **Patching RUNPATH in our own `postFixup` body.** autoPatchelfHook runs after
  it and rewrites the RUNPATH, dropping the addition.
- **Microsoft's tarball on Linux.** Depends on distro icu/openssl, drops the
  pinned version, splits macOS and Linux, and reverses pwsh's nix tier
  (decision 0002).

**Consequence:** pwsh is built locally instead of substituted from
cache.nixos.org: a copy of the release tarball plus autoPatchelf, seconds per
nixpkgs bump. `tests/nix/build_scope_env.sh` fails if pwsh exports
`LD_LIBRARY_PATH` or cannot load ICU, so an upstream change to the package
(new library, renamed wrapper) surfaces on the next pin bump. Darwin keeps the
upstream package: its wrapper sets `DYLD_FALLBACK_LIBRARY_PATH`, which dyld
consults only when a library is missing at its install name, and nix binaries
reference absolute store paths. The `nix/setup.sh` entry scrub stays for one
upgrade cycle (CQ-006), because the run that installs this build starts from
the old pwsh.
