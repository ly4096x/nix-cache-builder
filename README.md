# nix-cache-builder

A single container that acts as **both** a Nix remote builder (ssh-ng) and
a binary cache (harmonia, a nix-serve-compatible cache in Rust).  A
separate verifier container exercises both paths end-to-end so you can
confirm a fresh deployment actually works.

```
host                                  container  (s6-svscan as PID 1)
─────────────────────────────────     ─────────────────────────────────
nixos-rebuild                ──ssh-ng──▶  sshd → nix-daemon (root)
                                                 builds in /nix/store
                                                 ▼
                                          harmonia (nixbuild, non-root)
nix-store --realize          ◀──HTTP─────  serves narinfo / NAR
```

- s6-svscan is PID 1 and supervises the three services below
- nix-daemon runs as root (required to own `/nix/store`)
- sshd accepts only the unprivileged `nixbuild` user
- harmonia (HTTP binary cache) runs as `nixbuild`, launched by s6 via
  `s6-setuidgid`
- actual build processes still sandbox under the base image's `nixbld*`
  system users via nix-daemon

---

## 1. Start the server on a Docker/Podman host

```sh
git clone https://github.com/ly4096x/nix-cache-builder.git
cd nix-cache-builder
docker compose up -d nix-builder
```

The compose file builds `./server` locally on first run.  Ports exposed
on the host:

| Port | Purpose                             |
|------|-------------------------------------|
| 2222 | ssh-ng remote builder               |
| 5000 | harmonia binary cache (HTTP)        |

### Use the prebuilt GHCR image instead

The image is just the server; you still need the two named volumes and
the port mappings.  `nix-store` holds `/nix/store`; `nix-builder-keys`
holds the binary-cache signing key, the `nixbuild` SSH key, **and** the
sshd host keys — so the host fingerprint clients see is stable across
container recreation.  Self-contained `docker run`:

```sh
docker run -d --name nix-cache-builder \
  -p 2222:22 -p 5000:5000 \
  -v nix-store:/nix \
  -v nix-builder-keys:/shared/keys \
  --restart unless-stopped \
  ghcr.io/ly4096x/nix-cache-builder:latest
```

…or as a standalone `docker-compose.yml`:

```yaml
services:
  nix-builder:
    image: ghcr.io/ly4096x/nix-cache-builder:latest
    ports:
      - "2222:22"
      - "5000:5000"
    volumes:
      - nix-store:/nix
      - nix-builder-keys:/shared/keys
    restart: unless-stopped

volumes:
  nix-store:
  nix-builder-keys:
```

> The package is private until visibility is flipped on the GitHub
> Packages page.  Until then, `docker login ghcr.io` first.

### Bring your own SSH key

By default the server generates a key for `nixbuild` on first start so
the verifier can authenticate out of the box.  Any additional pubkeys you
provide are **appended** to `nixbuild`'s `authorized_keys` on every boot
(then deduped) — useful when you'd rather let NixOS clients log in with
keys they already control.

**1. Inline via `AUTHORIZED_KEYS` env** (newline-separated, one pubkey per line):

```sh
AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" docker compose up -d nix-builder
```

The bundled `docker-compose.yml` already forwards this env to the container.
With raw `docker run`, pass `-e AUTHORIZED_KEYS=...`.

**2. Mount a directory of `*.pub` files** at `/shared/authorized_keys.d/`:

```sh
mkdir -p ./team-keys
cp ~/.ssh/id_ed25519.pub ./team-keys/me.pub      # add as many as you want

docker run -d --name nix-cache-builder \
  -p 2222:22 -p 5000:5000 \
  -v nix-store:/nix \
  -v nix-builder-keys:/shared/keys \
  -v $(pwd)/team-keys:/shared/authorized_keys.d:ro \
  ghcr.io/ly4096x/nix-cache-builder:latest
```

Restart the container after changing keys; `authorized_keys` is rebuilt
on each boot.

### Verify it actually builds and caches

```sh
docker compose run --rm verifier
```

`verifier` exits 0 iff all six checks pass:

1. `GET /nix-cache-info` reachable
2. A fresh timestamped derivation builds remotely via ssh-ng
3. Its narinfo is published by harmonia
4. narinfo carries the cache signature
5. NAR payload is downloadable
6. After local delete, `nix copy --from` repulls it (validates signature trust end-to-end)

### Where the keys live

Generated once on first server start, persisted in the `nix-builder-keys`
docker volume:

| Path in container                       | What it is                                                                 |
|-----------------------------------------|----------------------------------------------------------------------------|
| `/shared/keys/id_ed25519`               | SSH private key the client uses to log in as `nixbuild`                    |
| `/shared/keys/id_ed25519.pub`           | Public counterpart, already in `nixbuild`'s `authorized_keys`              |
| `/shared/keys/cache-pub-key.pem`        | Binary-cache public key — consumers add this to `trusted-public-keys`      |
| `/shared/keys/host_keys/ssh_host_*_key` | sshd host keys.  Living in the volume means the host fingerprint stays the same across `docker compose down && up`, so clients don't see "host key changed" warnings. |

Read them with `docker exec nix-cache-builder cat /shared/keys/<file>`.

### Optional: ccache

The server creates `/nix/var/cache/ccache` (owned `root:nixbld`, mode
`2770`) and lists it in `extra-sandbox-paths`, so builds compiled with a
ccache-wrapped compiler share one persistent compiler cache (it lives
under `/nix`, so the `nix-store` volume persists it).  This is opt-in on
the **client** side — see [§3](#3-optional-ccache-for-near-miss-rebuilds).

ccache hits are most reliable with the Nix sandbox on (deterministic
`/build` directory).  The sandbox is off by default for rootless-podman
compatibility; turn it on where user namespaces work:

```sh
docker run -d --name nix-cache-builder -e NIX_SANDBOX=true \
  -p 2222:22 -p 5000:5000 \
  -v nix-store:/nix -v nix-builder-keys:/shared/keys \
  ghcr.io/ly4096x/nix-cache-builder:latest
```

### Optional: filesystem-image builds (user namespaces)

Derivations whose *build* opens a user namespace — e.g. image builders that
emit a root-owned tree with `unshare --map-root-user … mkfs.btrfs -r` — need
the container to allow unprivileged `unshare(CLONE_NEWUSER)`.  Docker's
default seccomp profile denies it for the unprivileged `nixbld*` users
(podman's default allows it).  The bundled `docker-compose.yml` already sets
this; with raw `docker run` add:

```sh
  --security-opt seccomp=unconfined
```

The host kernel must also permit unprivileged user namespaces
(`sysctl kernel.unprivileged_userns_clone=1` and a non-zero
`user.max_user_namespaces`; on Ubuntu 24.04 also
`kernel.apparmor_restrict_unprivileged_userns=0`).

---

## 2. Set up a NixOS host to use the server

You need three things on the NixOS box:

1. The SSH private key, root-readable
2. The cache public key string
3. A NixOS module that wires `nix.buildMachines` + `nix.settings`

### 2.1 Copy the secrets onto the host

Run on the NixOS host, pointing `SERVER` at wherever the container is:

```sh
SERVER=user@server-host                 # or `localhost` if container runs here
ssh "$SERVER" docker exec nix-cache-builder cat /shared/keys/id_ed25519 \
  | sudo install -D -m 0600 /dev/stdin /etc/nix-cache-builder/id_ed25519

ssh "$SERVER" docker exec nix-cache-builder cat /shared/keys/cache-pub-key.pem \
  | sudo tee /etc/nix-cache-builder/cache-pub-key.pem
```

If the container runs on the same machine, drop `ssh "$SERVER"`.

### 2.2 Add a NixOS module

Drop this in (e.g. `modules/nix-cache-builder.nix`) and import it from
your host configuration:

```nix
{ ... }:
{
  nix = {
    distributedBuilds = true;

    buildMachines = [{
      # Refers to the SSH alias defined in programs.ssh.extraConfig below;
      # change one place to swap host/port (e.g. local docker -> remote box).
      hostName = "nix-cache-builder";
      sshUser = "nixbuild";
      sshKey = "/etc/nix-cache-builder/id_ed25519";
      protocol = "ssh-ng";
      systems = [ "x86_64-linux" ];
      maxJobs = 4;
      speedFactor = 1;
      supportedFeatures = [ "kvm" "big-parallel" "nixos-test" "benchmark" ];
    }];

    settings = {
      builders-use-substitutes = true;

      # Read the actual key from /etc/nix-cache-builder/cache-pub-key.pem
      # on the host and paste its value here.
      trusted-public-keys = [
        "nix-cache-builder-1:PASTE-VALUE-FROM-cache-pub-key.pem"
      ];

      substituters = [ "http://CACHE-HOST:5000" ];   # localhost:5000 if local

      # Nix caches the pre-build "not found" substituter probe for 1h by
      # default and never re-queries after the builder adds the path.
      # Setting the negative TTL to 0 keeps substitution responsive.
      narinfo-cache-negative-ttl = 0;
    };
  };

  programs.ssh.extraConfig = ''
    Host nix-cache-builder
        HostName SSH-HOST
        Port 2222
        User nixbuild
        IdentityFile /etc/nix-cache-builder/id_ed25519
        IdentitiesOnly yes
        StrictHostKeyChecking accept-new
  '';
}
```

Replace `SSH-HOST` / `CACHE-HOST` with the actual addresses, and paste the
public key string in `trusted-public-keys`.

### 2.3 Apply

```sh
sudo nixos-rebuild switch --flake .#yourhost
```

### 2.4 Smoke test

Build a tiny derivation and watch it go remote:

```sh
nix-build --no-out-link -E '
  derivation {
    name = "smoke-test";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "echo hello > $out" ];
  }'
```

Expected: a `building '...drv' on 'ssh-ng://nixbuild@nix-cache-builder'…`
line, then the path appears locally **and** is queryable as
`http://CACHE-HOST:5000/<hash>.narinfo`.

---

## 3. Optional: ccache for near-miss rebuilds

The binary cache already eliminates *exact* rebuilds.  ccache adds the
**near-miss** case: a package whose derivation hash changed (version bump,
patch, toolchain bump) but whose translation units are mostly identical —
ccache serves the unchanged `.o` files instead of recompiling.  Only worth
it for heavy C/C++ packages you rebuild often.

Because remote builders *realize* derivations the client already
*instantiated*, the compiler is fixed at instantiation time — so the
ccache wrapper has to be selected **on the client**.  The server just
provides the writable `/nix/var/cache/ccache` (§1).

Add this module on the client and import it from your host config:

```nix
# nix-ccache.nix
{ config, lib, ... }:
let cfg = config.services.nixCcache; in {
  options.services.nixCcache = {
    enable = lib.mkEnableOption "ccache-wrapped builds for selected packages";
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "ffmpeg" "mpv" ];
      description = "pkgs attr names to rebuild through ccacheStdenv.";
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = [
      # Wrapper env is baked into the derivation, so it runs on the builder.
      # CCACHE_UMASK=007 keeps the cache group-writable across nixbld* users;
      # CCACHE_NOHASHDIR + the sloppiness set let builds hit across nix's
      # per-build temp dirs (needed when the builder runs sandbox = false).
      (final: prev: {
        ccacheWrapper = prev.ccacheWrapper.override {
          extraConfig = ''
            export CCACHE_DIR=/nix/var/cache/ccache
            export CCACHE_UMASK=007
            export CCACHE_COMPRESS=1
            export CCACHE_NOHASHDIR=1
            export CCACHE_SLOPPINESS=locale,time_macros,include_file_mtime,include_file_ctime,file_stat_matches,random_seed
          '';
        };
      })
      (final: prev:
        lib.genAttrs cfg.packages (name:
          prev.${name}.override { stdenv = final.ccacheStdenv; }))
    ];
  };
}
```

```nix
# Generic C/C++ packages: list them by pkgs attr name.
services.nixCcache = { enable = true; packages = [ "ffmpeg" ]; };
```

The Linux kernel is the classic ccache win — a `.config` tweak or minor
version bump recompiles thousands of mostly-identical translation units.
It's selected through `boot.kernelPackages`, not the `packages` list above
(`pkgs.ccacheStdenv` is the wrapper-overridden one once the module is
enabled):

```nix
# in your host config (which has `pkgs` in scope)
boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.linux.override {
  stdenv = pkgs.ccacheStdenv;
});
```

The first build of a selected package populates the cache (mostly misses);
a later rebuild with a changed derivation hash but unchanged sources is
served from ccache.  Inspect hit rates on the server:

```sh
docker exec nix-cache-builder sh -c \
  'CCACHE_DIR=/nix/var/cache/ccache "$(ls /nix/store/*-ccache-*/bin/ccache | head -1)" -s'
```

---

## License

See [LICENSE](LICENSE).
