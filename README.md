# nix-cache-builder

A single container that acts as **both** a Nix remote builder (ssh-ng) and
a binary cache (nix-serve).  A separate verifier container exercises both
paths end-to-end so you can confirm a fresh deployment actually works.

```
host                                  container
─────────────────────────────────     ─────────────────────────────────
nixos-rebuild                ──ssh-ng──▶  sshd → nix-daemon (root)
                                                 builds in /nix/store
                                                 ▼
                                          nix-serve (nixbuild, non-root)
nix-store --realize          ◀──HTTP─────  serves narinfo / NAR
```

- nix-daemon runs as root (required to own `/nix/store`)
- sshd accepts only the unprivileged `nixbuild` user
- nix-serve runs as `nixbuild` (privileges dropped via `setpriv`)
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
| 5000 | nix-serve binary cache (HTTP)       |

### Use the prebuilt GHCR image instead

The image is just the server; you still need the two named volumes (so
the store and the generated cache/SSH keys survive container recreation)
and the port mappings.  Self-contained `docker run`:

```sh
docker run -d --name nix-cache-builder \
  -p 2222:22 -p 5000:5000 \
  -v nix-cache-builder-store:/nix \
  -v nix-cache-builder-keys:/shared/keys \
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
      - shared-keys:/shared/keys
    restart: unless-stopped

volumes:
  nix-store:
  shared-keys:
```

> The package is private until visibility is flipped on the GitHub
> Packages page.  Until then, `docker login ghcr.io` first.

### Verify it actually builds and caches

```sh
docker compose run --rm verifier
```

`verifier` exits 0 iff all six checks pass:

1. `GET /nix-cache-info` reachable
2. A fresh timestamped derivation builds remotely via ssh-ng
3. Its narinfo is published by nix-serve
4. narinfo carries the cache signature
5. NAR payload is downloadable
6. After local delete, `nix copy --from` repulls it (validates signature trust end-to-end)

### Where the keys live

Generated once on first server start, persisted in the `shared-keys`
docker volume:

| Path in container               | What it is                                          |
|---------------------------------|-----------------------------------------------------|
| `/shared/keys/id_ed25519`       | SSH private key the client uses to log in as `nixbuild` |
| `/shared/keys/id_ed25519.pub`   | Public counterpart, already in `nixbuild`'s `authorized_keys` |
| `/shared/keys/cache-pub-key.pem` | Binary-cache public key — consumers add this to `trusted-public-keys` |

Read them with `docker exec nix-cache-builder cat /shared/keys/<file>`.

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

## License

See [LICENSE](LICENSE).
