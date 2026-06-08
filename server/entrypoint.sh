#!/usr/bin/env bash
# Bring up multi-user nix-daemon, sshd (for ssh-ng remote builds) and
# nix-serve (binary cache HTTP) in one container.
#
#   - nix-daemon runs as root (required to own /nix/store and spawn nixbld*
#     sandbox users).
#   - sshd accepts only the unprivileged `nixbuild` user; remote builds run
#     through nix-daemon over the daemon socket.
#   - nix-serve runs as the unprivileged `nixbuild` user.
set -euo pipefail

# Make nix-installed tools (su, sshd, ssh-keygen, nix-serve, ...) visible.
export PATH=/usr/local/bin:/root/.nix-profile/bin:${PATH:-/usr/bin:/bin}

KEY_DIR=/shared/keys
CACHE_NAME="${CACHE_NAME:-nix-cache-builder-1}"

mkdir -p "$KEY_DIR"

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

# 4. nix-daemon (root) — provides the /nix/var/nix/daemon-socket socket that
#    nixbuild and other unprivileged users talk to.
echo "[start] nix-daemon"
nix-daemon &
DAEMON_PID=$!

for _ in $(seq 1 60); do
    [ -S /nix/var/nix/daemon-socket/socket ] && break
    sleep 0.25
done
[ -S /nix/var/nix/daemon-socket/socket ] || {
    echo "ERROR: nix-daemon socket did not appear"
    exit 1
}

# 5. nix-serve (non-root) — HTTP binary cache backed by the local store.
# `setpriv` (util-linux) drops to the build user without PAM, which the
# scratch-built nix image doesn't ship.
echo "[start] nix-serve on :5000 (user=nixbuild)"
setpriv --reuid=nixbuild --regid=nixbuild --init-groups \
    --inh-caps=-all -- env \
        PATH=/usr/local/bin:/root/.nix-profile/bin \
        HOME=/home/nixbuild \
        NIX_SECRET_KEY_FILE="$KEY_DIR/cache-priv-key.pem" \
        nix-serve --listen 0.0.0.0:5000 &
SERVE_PID=$!

cleanup() {
    echo "[stop] shutting down"
    kill "$SERVE_PID" "$DAEMON_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# 6. sshd in foreground
echo "[start] sshd on :22"
exec /usr/local/bin/sshd -D -e
