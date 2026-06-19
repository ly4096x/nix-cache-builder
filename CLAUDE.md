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
- **`nixbuild` is non-root.**  sshd accepts only this user; harmonia is
  launched by s6 via `s6-setuidgid nixbuild`; actual build processes
  are still sandboxed under the base image's `nixbld*` system users
  via nix-daemon.
- **s6-svscan is PID 1.**  `server/s6/{nix-daemon,harmonia,sshd}/run`
  are the three supervised services; s6-svscan restarts crashes
  automatically and forwards SIGTERM to the whole tree.  `entrypoint.sh`
  only does init (key generation, authorized_keys rebuild) then `exec`s
  `s6-svscan /etc/s6/sv`.  Child stdout/stderr inherit from svscan so
  `docker logs` sees everything in one stream.
- **harmonia (Rust) replaces nix-serve (Perl).**  Drop-in HTTP API
  compatibility — same `/nix-cache-info`, `/<hash>.narinfo`, and
  `/nar/<hash>.nar` shape, same signing-key format.  Single async
  process, no prefork workers, no orphan-on-master-SIGKILL footgun.
- **SSH alias indirection** in the consuming NixOS config (`nix.buildMachines`
  references an alias rather than a literal `host:port`) — lets the
  container move local↔remote with a one-line change.

## Runtime package list lives in `install-packages.sh`

The Dockerfile's nix-env step is just `RUN /install-packages.sh`.  The
same script also runs from `entrypoint.sh` as a self-heal step on cold
start: when the user reuses a persistent `/nix` volume that was
populated by a previous image build, the new image's `/usr/local/bin`
symlinks point at store paths the volume doesn't contain.  The
entrypoint walks a list of critical tools (`s6-svscan`,
`s6-setuidgid`, `harmonia-cache`, `nix-daemon`, `sshd`, `ssh-keygen`,
`nix-store`, `sort`); if any fail `command -v`, it re-runs
`install-packages.sh` so the missing packages land in the volume's
nix profile.

Important detail: `install-packages.sh` runs `nix-channel --update`
first.  The nixos/nix base image leaves the `nixpkgs` channel
subscribed but never unpacked, so a fresh `nix-env -iA nixpkgs.*` at
runtime would 404 with "attribute 'nixpkgs' not found".

Adding or removing a runtime package means editing **only**
`install-packages.sh`.  Adding a tool used by the entrypoint also means
adding it to the canary list in the for-loop.

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

## Keys volume (`nix-builder-keys` -> `/shared/keys`)

Everything stateful that survives container recreation lives in this one
volume:

- `cache-priv-key.pem` / `cache-pub-key.pem` — binary-cache signing pair
- `id_ed25519` / `id_ed25519.pub` — nixbuild SSH key, used by the
  verifier (and any client that fetches it)
- `host_keys/ssh_host_{rsa,ecdsa,ed25519}_key` — sshd host keys,
  referenced directly by `server/sshd_config` so the fingerprint stays
  stable across `docker compose down && up`

Anything not in this volume is regenerated on boot (e.g. nixbuild's
`authorized_keys`), so when adding new state, decide deliberately
whether it belongs in the volume.

## `nixbuild` authorized_keys

Rebuilt fresh on every boot — never appended in place — from three
sources, deduped (`sort -u`):

1. `$KEY_DIR/id_ed25519.pub` (the auto-generated key the verifier uses)
2. `$AUTHORIZED_KEYS` env var, one pubkey per line
3. Every `*.pub` under `/shared/authorized_keys.d/`

The bundled `docker-compose.yml` forwards `AUTHORIZED_KEYS` through to
the container.  To remove a key, drop it from the env / directory and
restart the container — there is no in-place "remove key" path.

If you change the entrypoint's authorized_keys logic, make sure the
auto-generated key still ends up first so the verifier keeps working
without operator setup.

## ccache

`entrypoint.sh` creates `/nix/var/cache/ccache` (`root:nixbld`, mode
`2770` setgid) and `nix.conf` lists it in `extra-sandbox-paths`.  That's
the whole server side — a persistent, build-user-writable compiler cache
under `/nix` (so the `nix-store` volume persists it).

The build user creates the cache shards on first use with
`CCACHE_UMASK=007`, so they stay group-writable across all 32 `nixbld*`
users.  **Don't run `ccache` (or anything that writes the cache) as root
in the container** — root-owned shards get mode `0755` and then the
build users hit `Permission denied` on `stats.lock` and silently stop
caching (0 cacheable calls, cache stays empty).  Found this the hard way
during VM verification.

ccache is opt-in from the **client**: derivations are instantiated on the
client, so the ccache-wrapped compiler is selected there (a
`ccacheStdenv` overlay — see README §3), not on the builder.  Hit rates
are best with `NIX_SANDBOX=true` (deterministic `/build` dir); the
entrypoint appends a `sandbox =` override when that env is set.  Verified
in a VM: a near-miss rebuild of `hello` (new derivation hash, unchanged
sources) was ~99% ccache hits through the ssh-ng remote builder, in both
sandbox modes.
