# nix-cache-builder

Single Docker container that runs a Nix remote builder (ssh-ng) **and**
binary cache (nix-serve) for offloading NixOS builds.  A separate verifier
container exercises both paths end-to-end.

## Layout

- `docker-compose.yml` — orchestrates `nix-builder` and `verifier`
- `server/` — `Dockerfile`, `entrypoint.sh`, `nix.conf`, `sshd_config`
- `verifier/` — `Dockerfile`, `entrypoint.sh`, `verify.sh`
- `.github/workflows/` — CI: verify + publish to ghcr.io

## Commands

```sh
docker compose build                              # build both images
docker compose up -d nix-builder                  # start server only
docker compose run --rm verifier                  # one-shot verification (must exit 0)
docker compose down -v                            # reset everything
```

Ports on the host: `2222` (ssh-ng) and `5000` (nix-serve HTTP).

## Architecture decisions

- **Single container for builder + cache.**  nix-daemon owns `/nix/store`
  and nix-serve reads from it directly, so co-locating avoids a second
  store and double signing.
- **`nixbuild` is non-root.**  sshd accepts only this user; nix-serve runs
  as it (dropped via `setpriv`); actual build processes are still sandboxed
  under the base image's `nixbld*` system users via nix-daemon.
- **SSH alias indirection** in the consuming NixOS config (`nix.buildMachines`
  references an alias rather than a literal `host:port`) — lets the
  container move local↔remote with a one-line change.

## Non-obvious things (rediscover at your peril)

| Symptom | Cause | Fix |
|---|---|---|
| `addgroup: command not found` in build | nixos/nix base is not Alpine | use `groupadd`/`useradd` from `nixpkgs.shadow` |
| `groupadd: cannot open /etc/group` | `/etc/{passwd,group,shadow}` are symlinks into the read-only nix store | replace with writable copies before useradd (see `server/Dockerfile`) |
| `User nixbuild not allowed because account is locked` (sshd auth) | `useradd -r` writes `!` in shadow; sshd refuses locked accounts even for pubkey-only auth | `sed -i 's/^nixbuild:[^:]*:/nixbuild:*:/' /etc/shadow` |
| `runuser: Critical error - immediate abort` | base image ships no PAM stack | use `setpriv` (also from util-linux) instead |
| `su: command not found` in entrypoint | `nixpkgs.shadow` doesn't include `su` (separate output); also nix-installed bins aren't on the default PATH | install `util-linux`; `export PATH=/usr/local/bin:/root/.nix-profile/bin:$PATH` at top of entrypoint |
| `useradd: Warning: missing or non-executable shell '/bin/bash'` | `/bin/bash` doesn't exist in the scratch-built base | point shell at `/usr/local/bin/bash` (the symlink the Dockerfile creates) |
| `Privilege separation user sshd does not exist` | OpenSSH needs an `sshd` privsep account | `groupadd -r sshd && useradd -r -g sshd ...` |
| Verifier passes 5/6, fails the cache round-trip | Nix caches the pre-build "not in substituter" probe for 1h; never re-queries after the builder adds the path | client `nix.conf` must set `narinfo-cache-negative-ttl = 0` |
| `sed: command not found` in verifier | verifier image didn't install `gnused`/`gnugrep`/`gawk` | install them via nix-env |

## Verifier contract

`verifier/verify.sh` exits 0 iff all six steps pass:

1. `GET /nix-cache-info` reachable
2. Fresh timestamped derivation builds remotely via ssh-ng
3. Output's narinfo is published by nix-serve
4. narinfo carries our cache signature (`nix-cache-builder-1:…`)
5. NAR payload is downloadable via HTTP
6. After local delete, `nix copy --from $CACHE_URL` repulls it (validates `trusted-public-keys` end-to-end)

CI runs this on every push; the publish job is gated on it.

## Local env quirks

- `docker` on this dev host is podman 5.8.2.  `docker compose` resolves to
  `podman-compose`.  CI uses real Docker.

## Cache key

Generated once at first server start, persisted in the `shared-keys`
docker volume.  Public key lives at `/shared/keys/cache-pub-key.pem` on
the server; copy that value into the consumer's `trusted-public-keys`.
