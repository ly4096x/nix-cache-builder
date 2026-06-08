#!/usr/bin/env bash
# Init for the nix-cache-builder container:
#   1. generate / refresh keys under /shared/keys (the nix-builder-keys volume)
#   2. rebuild /home/nixbuild/.ssh/authorized_keys from the operator inputs
#   3. hand off to supervisord, which actually runs nix-daemon, nix-serve
#      and sshd (definitions in /etc/supervisord.conf).
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
for tool in supervisord nix-serve nix-daemon sshd ssh-keygen nix-store sort pkill; do
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

# 4. Hand off to supervisord, which runs nix-daemon, nix-serve and sshd
#    (priorities ordered so nix-daemon starts first; nix-serve waits on
#    the daemon socket before launching).  supervisord becomes PID 1,
#    reaps zombies, restarts crashed children, and forwards SIGTERM to
#    each program on container stop.
echo "[start] supervisord"
exec /usr/local/bin/supervisord -c /etc/supervisord.conf
