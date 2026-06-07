#!/usr/bin/env bash
# Wait for the server's shared keys + ports, write a client nix.conf that
# points at the server as both substituter and remote builder, then exec
# the verification script (or whatever the user passed).
set -euo pipefail

export PATH=/usr/local/bin:/root/.nix-profile/bin:${PATH:-/usr/bin:/bin}

SERVER_HOST="${SERVER_HOST:-nix-builder}"
SERVER_SSH_PORT="${SERVER_SSH_PORT:-22}"
SERVER_HTTP_PORT="${SERVER_HTTP_PORT:-5000}"
KEY_DIR="${KEY_DIR:-/shared/keys}"

wait_for() {
    local what="$1"; shift
    local i
    for i in $(seq 1 120); do
        if "$@" >/dev/null 2>&1; then
            echo "[wait] $what ready"
            return 0
        fi
        sleep 1
    done
    echo "ERROR: timed out waiting for $what"
    return 1
}

wait_for "shared signing key" test -f "$KEY_DIR/cache-pub-key.pem"
wait_for "shared ssh key"     test -f "$KEY_DIR/id_ed25519"
wait_for "sshd  $SERVER_HOST:$SERVER_SSH_PORT"   nc -z "$SERVER_HOST" "$SERVER_SSH_PORT"
wait_for "cache $SERVER_HOST:$SERVER_HTTP_PORT"  curl -fsS "http://$SERVER_HOST:$SERVER_HTTP_PORT/nix-cache-info"

# SSH client setup
mkdir -p /root/.ssh
install -m 600 "$KEY_DIR/id_ed25519" /root/.ssh/id_ed25519
ssh-keyscan -p "$SERVER_SSH_PORT" -H "$SERVER_HOST" > /root/.ssh/known_hosts 2>/dev/null

# Trust the server's cache key
PUB_KEY="$(tr -d '\n' < "$KEY_DIR/cache-pub-key.pem")"
export PUB_KEY

mkdir -p /etc/nix
cat > /etc/nix/nix.conf <<EOF
experimental-features = nix-command flakes

# Point at the server's HTTP cache first, fall back to upstream.
substituters = http://$SERVER_HOST:$SERVER_HTTP_PORT https://cache.nixos.org
trusted-public-keys = $PUB_KEY cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
# Default 1h negative TTL would cache the "not found" check Nix runs *before*
# the remote build adds the path, making the post-build substitution fail.
narinfo-cache-negative-ttl = 0

# Force every build to go through the remote builder (max-jobs=0 means we
# never build locally).  Builder spec is space-delimited:
#   uri  systems  ssh-key  max-jobs  speed-factor  supported-features
builders = ssh-ng://nixbuild@$SERVER_HOST x86_64-linux /root/.ssh/id_ed25519 4 1 kvm,big-parallel
builders-use-substitutes = true
max-jobs = 0
EOF

echo "[ready] client config written:"
sed 's/^/    /' /etc/nix/nix.conf

if [ "$#" -gt 0 ]; then
    exec "$@"
fi
exec /verify.sh
