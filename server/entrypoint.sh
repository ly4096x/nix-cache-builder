#!/usr/bin/env bash
# Init for the nix-cache-builder container:
#   1. generate / refresh keys under /shared/keys (the nix-builder-keys volume)
#   2. rebuild /home/nixbuild/.ssh/authorized_keys from the operator inputs
#   3. prepare the ccache directory + optional sandbox override
#   4. hand off to s6-svscan, which runs nix-daemon, harmonia and sshd
#      (definitions in /etc/s6/sv/).
set -euo pipefail

# Make nix-installed tools (su, sshd, ssh-keygen, nix-serve, ...) visible.
export PATH=/usr/local/bin:/root/.nix-profile/bin:${PATH:-/usr/bin:/bin}

KEY_DIR=/shared/keys
CACHE_NAME="${CACHE_NAME:-nix-cache-builder-1}"

mkdir -p "$KEY_DIR" /run

# Self-heal: when the user reuses a persistent /nix volume that was
# populated by an older image build, the new image's symlink farm in
# /usr/local/bin points at store paths the volume doesn't contain
# (e.g. /usr/local/bin/supervisord -> /root/.nix-profile/bin/supervisord
# -> missing-in-volume).  Detect by walking the critical tools; if any
# don't resolve to an executable file, re-run install-packages.sh so
# the missing packages land in the volume's nix profile.
for tool in s6-svscan s6-setuidgid harmonia-cache nix-daemon sshd ssh-keygen nix-store sort; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "[init] $tool missing — /nix volume is stale relative to image, running install-packages.sh"
        /install-packages.sh
        break
    fi
done

# 1. Binary-cache signing key (persisted across restarts via shared volume)
if [ ! -f "$KEY_DIR/cache-priv-key.pem" ]; then
    echo "[init] generating binary cache signing key ($CACHE_NAME)"
    nix-store --generate-binary-cache-key \
        "$CACHE_NAME" \
        "$KEY_DIR/cache-priv-key.pem" \
        "$KEY_DIR/cache-pub-key.pem"
fi
chown -R nixbuild:nixbuild "$KEY_DIR"
chmod 600 "$KEY_DIR/cache-priv-key.pem"
chmod 644 "$KEY_DIR/cache-pub-key.pem"

# 2. SSH key for the build user (shared with the verifier via volume)
if [ ! -f "$KEY_DIR/id_ed25519" ]; then
    echo "[init] generating ssh key for nixbuild user"
    ssh-keygen -t ed25519 -N "" -f "$KEY_DIR/id_ed25519" \
        -C "remote-builder@$CACHE_NAME" >/dev/null
fi
# Rebuilt from scratch every boot from the generated key plus any keys
# the operator supplied (env var and/or mounted directory).
AUTH_KEYS=/home/nixbuild/.ssh/authorized_keys
: > "$AUTH_KEYS"
cat "$KEY_DIR/id_ed25519.pub" >> "$AUTH_KEYS"

# Inline pubkeys via AUTHORIZED_KEYS env (one per line; ignore blanks)
if [ -n "${AUTHORIZED_KEYS:-}" ]; then
    printf '%s\n' "$AUTHORIZED_KEYS" | sed '/^[[:space:]]*$/d' >> "$AUTH_KEYS"
fi

# Mount-in pubkeys: any *.pub under /shared/authorized_keys.d
USER_AUTH_DIR=/shared/authorized_keys.d
if [ -d "$USER_AUTH_DIR" ]; then
    for f in "$USER_AUTH_DIR"/*.pub; do
        [ -r "$f" ] || continue
        cat "$f" >> "$AUTH_KEYS"
        printf '\n' >> "$AUTH_KEYS"
        echo "[init] added authorized_keys from $f"
    done
fi

# Dedup, fix perms, normalize ownership.
sort -u "$AUTH_KEYS" -o "$AUTH_KEYS"
chown nixbuild:nixbuild "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

# 3. SSH host keys — generated into the keys volume so the fingerprint
#    stays stable across container recreation.  sshd_config points at
#    these paths directly.
HOST_KEY_DIR="$KEY_DIR/host_keys"
mkdir -p "$HOST_KEY_DIR"
chmod 700 "$HOST_KEY_DIR"
for type in rsa ecdsa ed25519; do
    if [ ! -f "$HOST_KEY_DIR/ssh_host_${type}_key" ]; then
        echo "[init] generating ssh host key ($type)"
        ssh-keygen -t "$type" -N "" -f "$HOST_KEY_DIR/ssh_host_${type}_key" >/dev/null
    fi
    chmod 600 "$HOST_KEY_DIR/ssh_host_${type}_key"
    chmod 644 "$HOST_KEY_DIR/ssh_host_${type}_key.pub"
done

# 4. ccache: shared compiler cache for ccacheStdenv builds.  Lives under
#    /nix so it persists in the nix-store volume automatically.  Owned
#    root:nixbld with the setgid bit so every nixbld* build user writes
#    into one shared cache (the client's CCACHE_UMASK=007 keeps the
#    individual cache files group-readable across build users).
CCACHE_DIR=/nix/var/cache/ccache
mkdir -p "$CCACHE_DIR"
chown root:nixbld "$CCACHE_DIR"
chmod 2770 "$CCACHE_DIR"

# Optional runtime sandbox override.  Off by default (rootless-podman
# compatibility); set NIX_SANDBOX=true on hosts where user namespaces
# work to get deterministic /build dirs and far better ccache hit rates.
# A later `sandbox =` line in nix.conf wins over the baked-in default.
if [ -n "${NIX_SANDBOX:-}" ]; then
    echo "[init] overriding sandbox = $NIX_SANDBOX"
    printf 'sandbox = %s\n' "$NIX_SANDBOX" >> /etc/nix/nix.conf
fi

# 4b. Cross-architecture builds.  Nix refuses a derivation whose `system`
#     is neither our own nor listed in extra-platforms ("platform
#     mismatch"), so foreign platforms have to be declared explicitly —
#     nix does NOT infer them from the kernel's binfmt_misc table.
#
#     This only declares intent.  The actual emulation comes from
#     binfmt_misc handlers registered on the *host kernel*, which the
#     bundled `binfmt` compose service installs
#     (`docker compose --profile binfmt up binfmt`).  Because those are
#     registered with the F flag, nothing has to be installed here: no
#     qemu in this image, no extra-sandbox-paths entry.  Declaring a
#     platform whose handler is missing makes builds fail at exec time
#     rather than be rejected up front, so only set what you registered.
if [ -n "${EXTRA_PLATFORMS:-}" ]; then
    echo "[init] extra-platforms = $EXTRA_PLATFORMS"
    printf 'extra-platforms = %s\n' "$EXTRA_PLATFORMS" >> /etc/nix/nix.conf
fi

# 5. Hand off to s6-svscan, which runs nix-daemon, harmonia and sshd
#    from /etc/s6/sv/.  Each service's run script is a single 'exec',
#    so s6-svscan owns PID directly and restarts crashes automatically.
#    SIGTERM to s6-svscan stops the whole tree cleanly.
echo "[start] s6-svscan"
exec /usr/local/bin/s6-svscan /etc/s6/sv
