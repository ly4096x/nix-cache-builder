#!/usr/bin/env bash
# Build the static probe binaries entrypoint.sh execs at boot to report
# which foreign architectures this container can actually run.
#
# Runs at image build only, and only while install-packages.sh still has
# the nixpkgs channel unpacked (the Dockerfile drops it right after).
#
# Two deliberate choices:
#
#   --max-jobs 0  : substitute or skip.  The image build must never fall
#                   back to cross-compiling a toolchain for an arch whose
#                   static build happens not to be in the binary cache;
#                   a missing probe just means the boot report says
#                   "cannot determine" for that platform.
#   copy, not symlink : the probes must live outside /nix.  At runtime
#                   /nix is a user-supplied volume that may predate this
#                   image, so a store path baked in here is not
#                   guaranteed to exist (same failure mode the
#                   entrypoint's self-heal step exists for).
set -uo pipefail

PROBE_DIR=/usr/local/lib/binfmt-probe

# Platforms worth probing.  Keep in sync with the list register-binfmt.sh
# can register; anything not substitutable is skipped with a note.
PLATFORMS="
aarch64-linux
armv7l-linux
riscv64-linux
powerpc64le-linux
s390x-linux
"

mkdir -p "$PROBE_DIR"

for system in $PLATFORMS; do
    if out=$(nix-build '<nixpkgs>' -A pkgsStatic.hello \
                --argstr system "$system" \
                --max-jobs 0 --no-out-link 2>/dev/null) \
       && [ -x "$out/bin/hello" ]; then
        cp "$out/bin/hello" "$PROBE_DIR/$system"
        chmod 0755 "$PROBE_DIR/$system"
        echo "[probe] $system: $(wc -c < "$PROBE_DIR/$system") bytes"
    else
        echo "[probe] $system: not substitutable — skipped"
    fi
done
