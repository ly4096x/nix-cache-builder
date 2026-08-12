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
skipped=0
section() { printf '\n===> %s\n' "$*"; }
ok()      { printf '  PASS  %s\n' "$*"; passed=$((passed+1)); }
fail()    { printf '  FAIL  %s\n' "$*"; failed=$((failed+1)); }
skip()    { printf '  SKIP  %s\n' "$*"; skipped=$((skipped+1)); }

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

section "7. cross-architecture build via binfmt (optional)"
if [ -z "${VERIFY_PLATFORMS:-}" ]; then
    skip "VERIFY_PLATFORMS unset — set it (e.g. 'aarch64-linux') to exercise binfmt"
else
    # A foreign-arch derivation needs a foreign-arch builder binary, so
    # unlike the steps above this one cannot use a bare `derivation` with
    # /bin/sh — it has to come from nixpkgs.  The base image subscribes
    # the channel but never unpacks it, so fetch it now.  Only the *source*
    # is needed here (we evaluate, the server builds), but it is ~640 MB,
    # which is why this step is opt-in rather than part of the six.
    echo "      fetching nixpkgs channel (needed to express a foreign-arch drv)"
    nix-channel --update >/dev/null 2>&1 || true

    NATIVE=$(uname -m)
    for platform in $VERIFY_PLATFORMS; do
        EXPR_X="(import <nixpkgs> { system = \"$platform\"; }).runCommand
                  \"nix-cache-builder-xarch-${platform}-$TS\" {} \"uname -m > \$out\""
        if OUT_X=$(nix-build -E "$EXPR_X" --no-out-link 2>/tmp/xbuild.log); then
            GOT=$(cat "$OUT_X" 2>/dev/null)
            # Deliberately not compared against a per-platform table of
            # expected `uname -m` values: those do not match the nix
            # system name often enough to hardcode (powerpc64le-linux
            # reports ppc64le, and so on).  What actually matters is that
            # the builder did NOT quietly run it natively, which is the
            # only way this can pass while emulation is broken.
            if [ -n "$GOT" ] && [ "$GOT" != "$NATIVE" ]; then
                ok "$platform built on the server under emulation (uname -m = $GOT)"
            else
                fail "$platform reported '$GOT' — built natively, not emulated"
            fi
        else
            fail "$platform build failed"
            sed 's/^/      /' /tmp/xbuild.log
        fi
    done
fi

echo
echo "==============================="
echo "  passed:  $passed"
echo "  failed:  $failed"
echo "  skipped: $skipped"
echo "==============================="
if [ "$failed" -ne 0 ]; then
    echo "VERIFICATION FAILED"
    exit 1
fi
echo "VERIFICATION PASSED"
