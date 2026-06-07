#!/usr/bin/env bash
# End-to-end verification that the server is BUILDING (over ssh-ng) and
# CACHING (over nix-serve HTTP) as expected.
set -uo pipefail

export PATH=/usr/local/bin:/root/.nix-profile/bin:${PATH:-/usr/bin:/bin}

SERVER_HOST="${SERVER_HOST:-nix-builder}"
SERVER_HTTP_PORT="${SERVER_HTTP_PORT:-5000}"
CACHE_URL="http://$SERVER_HOST:$SERVER_HTTP_PORT"

passed=0
failed=0
section() { printf '\n===> %s\n' "$*"; }
ok()      { printf '  PASS  %s\n' "$*"; passed=$((passed+1)); }
fail()    { printf '  FAIL  %s\n' "$*"; failed=$((failed+1)); }

# A timestamp-unique derivation so the server is forced to build (not just
# substitute from cache.nixos.org).
TS=$(date -u +%s)
EXPR='derivation {
    name = "nix-cache-builder-verify-'"$TS"'";
    system = "x86_64-linux";
    builder = "/bin/sh";
    args = [ "-c" "echo built-on-server-'"$TS"' > $out" ];
}'

section "1. binary cache HTTP endpoint"
if curl -fsS "$CACHE_URL/nix-cache-info" > /tmp/cache-info && \
   grep -q '^StoreDir: /nix/store' /tmp/cache-info; then
    ok "GET $CACHE_URL/nix-cache-info"
    sed 's/^/      /' /tmp/cache-info
else
    fail "cache-info not reachable / malformed"
fi

section "2. instantiate + remote build via ssh-ng"
DRV=$(nix-instantiate --expr "$EXPR" 2>/dev/null) || {
    fail "nix-instantiate failed"
    DRV=""
}
echo "      drv: $DRV"

OUT=""
if [ -n "$DRV" ]; then
    # max-jobs=0 in /etc/nix/nix.conf means this MUST go over the builder.
    if OUT=$(nix-store --realize "$DRV" 2>/tmp/build.log); then
        ok "remote build produced $OUT"
        echo "      content: $(cat "$OUT" 2>/dev/null || echo '<unreadable>')"
    else
        fail "nix-store --realize failed"
        sed 's/^/      /' /tmp/build.log
    fi
fi

section "3. built path is published by nix-serve"
if [ -n "$OUT" ]; then
    HASH=$(basename "$OUT" | cut -d- -f1)
    # nix-serve generates narinfo on demand; small retry for ordering safety.
    for _ in 1 2 3 4 5; do
        if curl -fsS "$CACHE_URL/${HASH}.narinfo" > /tmp/narinfo; then break; fi
        sleep 1
    done
    if [ -s /tmp/narinfo ] && grep -q '^StorePath:' /tmp/narinfo; then
        ok "GET $CACHE_URL/${HASH}.narinfo"
        sed 's/^/      /' /tmp/narinfo
    else
        fail "narinfo missing from server cache"
    fi
fi

section "4. narinfo carries our cache signature"
if [ -s /tmp/narinfo ] && grep -q '^Sig: nix-cache-builder' /tmp/narinfo; then
    ok "Sig: line present and signed by nix-cache-builder-* key"
else
    fail "narinfo is unsigned or signed with wrong key"
fi

section "5. NAR payload is downloadable"
if [ -s /tmp/narinfo ]; then
    NAR_PATH=$(awk '/^URL:/ {print $2}' /tmp/narinfo)
    if curl -fsS -o /tmp/result.nar "$CACHE_URL/$NAR_PATH" && [ -s /tmp/result.nar ]; then
        ok "GET $CACHE_URL/$NAR_PATH ($(wc -c < /tmp/result.nar) bytes)"
    else
        fail "NAR not downloadable"
    fi
fi

section "6. round-trip: delete locally, pull from cache"
if [ -n "$OUT" ] && [ -e "$OUT" ]; then
    nix-store --delete "$OUT" --ignore-liveness >/dev/null 2>&1 || true
    # nix copy --from drives the substituter directly and verifies the
    # cache signature against our trusted-public-keys (no --no-check-sigs).
    if nix copy --from "$CACHE_URL" "$OUT" 2>/tmp/copy.log && [ -e "$OUT" ]; then
        ok "pulled $OUT from $CACHE_URL"
        echo "      content: $(cat "$OUT")"
    else
        fail "could not pull from cache"
        sed 's/^/      /' /tmp/copy.log
    fi
fi

echo
echo "==============================="
echo "  passed: $passed"
echo "  failed: $failed"
echo "==============================="
if [ "$failed" -ne 0 ]; then
    echo "VERIFICATION FAILED"
    exit 1
fi
echo "VERIFICATION PASSED"
