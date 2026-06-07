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
install -m 600 -o nixbuild -g nixbuild \
    "$KEY_DIR/id_ed25519.pub" /home/nixbuild/.ssh/authorized_keys

# 3. SSH host keys
for type in rsa ecdsa ed25519; do
    if [ ! -f "/etc/ssh/ssh_host_${type}_key" ]; then
        ssh-keygen -t "$type" -N "" -f "/etc/ssh/ssh_host_${type}_key" >/dev/null
    fi
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
