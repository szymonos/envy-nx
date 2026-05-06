# Coder Workspace - Nix Store Persistence

## Problem

After a Coder workspace stop/start cycle, all nix-installed packages are lost even though `/nix` appears to exist and `~/.config/nix-env/` configuration is intact.

## Root Cause

The Coder workspace container uses an **overlay filesystem** for `/` (including `/nix`), while only `/home/coder` is on a persistent volume (`/dev/sdb`).

```text
Persistent (/dev/sdb):        Ephemeral (overlay):
  /home/coder                    / (everything else)
  /var/lib/containers            /nix/store  <-- packages live here
  /var/lib/docker                /nix/var
```

On workspace restart:

1. The overlay is rebuilt from base image layers - `/nix/store` is reset to the image baseline (only `nix` binary itself, ~73 paths).
2. `/home/coder` survives - so `~/.config/nix-env/config.nix`, `~/.local/state/nix/profiles/`, and the `~/.nix-profile` symlink all persist.
3. The profile symlinks now point to store paths that **no longer exist** in `/nix/store`.
4. The image startup script runs `nix profile install nixpkgs#nix`, resetting the profile to contain only `nix-2.x`.
5. Result: `~/.nix-profile/bin/` has only nix commands; all user tools (rg, eza, bat, kubectl, starship, pwsh, etc.) are gone.

## Evidence

```text
$ df -h /nix
Filesystem  Size  Used Avail Use% Mounted on
overlay     291G   42G  249G  15%  /           <-- ephemeral

$ df -h /home/coder
Filesystem  Size  Used Avail Use% Mounted on
/dev/sdb     32G  6.8G   25G  22%  /home/coder  <-- persistent

$ nix profile list
Name:  nix
Store: /nix/store/zwz1d55mxmc6isanh1dzrhnfjbdk5hk3-nix-2.34.5
# Only nix itself - all other packages gone

$ ls /nix/store/ | wc -l
73  # Should be 500+ with full scope set
```

## Recommendations

### Option A: Persistent volume for `/nix` (preferred)

Mount `/nix` on persistent storage. This gives **instant startup** with no rebuild time.

**Approach 1 - subpath of home volume:**

```yaml
# Kubernetes pod spec / Coder template
volumeMounts:
  - name: home
    mountPath: /nix
    subPath: .nix-store
```

**Approach 2 - Terraform template with dedicated volume:**

```hcl
resource "kubernetes_persistent_volume_claim" "nix_store" {
  metadata {
    name = "nix-store-${data.coder_workspace.me.id}"
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = { storage = "20Gi" }
    }
  }
}
```

**Approach 3 - bind mount from home (simplest, Docker-based):**

```bash
# In Coder startup or Dockerfile
mkdir -p /home/coder/.nix-persist
mount --bind /home/coder/.nix-persist /nix
```

> Note: bind mounts require privileges; a volume mount in the pod spec is cleaner.

**Pros:** Zero startup cost, packages survive restarts, GC roots work normally.
**Cons:** Requires Coder template modification; increases persistent volume usage.

### Option B: Export/import store closure on persistent volume

Cache the nix store closure as a NAR archive on the persistent home volume.

**After successful setup (one-time or periodic):**

```bash
nix-store --export $(nix-store -qR ~/.nix-profile) > ~/.nix-cache/store.nar
```

**In Coder startup script:**

```bash
#!/usr/bin/env bash
set -eo pipefail

if [[ -f "$HOME/.nix-cache/store.nar" ]] && ! [[ -x "$HOME/.nix-profile/bin/rg" ]]; then
  echo "Restoring nix store from cache..."
  nix-store --import < "$HOME/.nix-cache/store.nar"
  # Rebuild the profile link
  nix build --no-link "$HOME/.config/nix-env#default" \
    && nix profile install --profile "$HOME/.local/state/nix/profiles/profile" "$HOME/.config/nix-env"
fi
```

**Pros:** No template changes needed; works with current infra; seconds to restore (local I/O).
**Cons:** Duplicates store on disk (~2-5 GB NAR); must regenerate cache after scope changes.

### Option C: Rebuild from flake on startup (fallback)

Simply re-run setup.sh in the Coder startup script:

```bash
#!/usr/bin/env bash
if ! command -v rg &>/dev/null && [[ -d "$HOME/.config/nix-env" ]]; then
  echo "Nix profile missing - rebuilding..."
  cd "$HOME/.config/nix-env"
  nix profile install --profile "$HOME/.local/state/nix/profiles/profile" .
fi
```

Or call the full setup:

```bash
/path/to/envy-nx/nix/setup.sh
```

**Pros:** Always up-to-date; no extra disk usage; no template changes.
**Cons:** Downloads packages from cache.nixos.org on every start (2-10 minutes depending on scope count and network).

## Recommendation

**Use Option A** if you control the Coder template - it is the only solution with zero startup latency. A subpath mount from the existing home PVC is the simplest implementation.

If template changes are not possible, **use Option B** - the NAR import approach gives near-instant restores (~10-30 seconds) without network access, at the cost of ~3-5 GB of duplicate storage on the home volume.

Option C should only be used as a temporary workaround.
