#!/usr/bin/env bash
# Register qemu-user binfmt_misc handlers so the builder can run foreign
# architectures.
#
# One-shot: this script registers and exits.  The registrations outlive
# the container because every handler is written with the `F`
# (fix-binary) flag — the kernel opens the interpreter at *registration*
# time and keeps that file description forever.  Consequences:
#
#   - the nix-builder container needs no qemu of its own, and no
#     bind-mount of the interpreter
#   - nix's build sandbox needs no extra-sandbox-paths entry for qemu
#     (this is why NixOS' own binfmt module only adds /run/binfmt to the
#     sandbox when fixBinary is off)
#
# The F flag does NOT, however, make the interpreter's location
# irrelevant.  Staging it inside this container's own filesystem
# produces handlers that work from the host and from rootful containers
# but fail with "Exec format error" in a *rootless* one — the held file
# description points into an overlay that a nested user namespace cannot
# use.  Measured directly: same registration, same kernel, interpreter
# under /usr/local/bin -> rootless fails; interpreter under a
# host-mounted /run/binfmt -> rootless prints aarch64.  So we copy the
# emulator to INTERP_DIR, which must be a bind mount from the host.
#
# binfmt_misc is global to the kernel, not per-namespace, so registering
# here affects the whole host.  That is the point: it is what lets an
# unprivileged nix-builder execute aarch64 binaries.  It also means this
# container needs CAP_SYS_ADMIN (compose runs it privileged) and that
# the effect is host-wide and survives until reboot or --unregister.
set -euo pipefail

export PATH=/usr/local/bin:/root/.nix-profile/bin:${PATH:-/usr/bin:/bin}

BINFMT_DIR=/proc/sys/fs/binfmt_misc

# Nix system name -> qemu-user binary.  Keys are what you would put in
# nix's `extra-platforms` / a client's `nix.buildMachines.systems`.
qemu_for() {
    case "$1" in
        aarch64-linux)     echo qemu-aarch64 ;;
        armv7l-linux)      echo qemu-arm ;;
        armv6l-linux)      echo qemu-arm ;;
        riscv64-linux)     echo qemu-riscv64 ;;
        powerpc64le-linux) echo qemu-ppc64le ;;
        s390x-linux)       echo qemu-s390x ;;
        mips64el-linux)    echo qemu-mips64el ;;
        i686-linux)        echo qemu-i386 ;;
        loongarch64-linux) echo qemu-loongarch64 ;;
        *)                 echo "" ;;
    esac
}

# ELF magic + mask per system, copied verbatim from
# nixpkgs' nixos/lib/binfmt-magics.nix so we inherit upstream's
# vetted byte patterns instead of hand-transcribing them.
magic_for() {
    case "$1" in
        aarch64-linux)     printf '%s' '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00' ;;
        armv7l-linux|armv6l-linux)
                           printf '%s' '\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00' ;;
        riscv64-linux)     printf '%s' '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xf3\x00' ;;
        powerpc64le-linux) printf '%s' '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x15\x00' ;;
        s390x-linux)       printf '%s' '\x7fELF\x02\x02\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x16' ;;
        mips64el-linux)    printf '%s' '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x08\x00' ;;
        i686-linux)        printf '%s' '\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x06\x00' ;;
        loongarch64-linux) printf '%s' '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x02\x01' ;;
    esac
}

mask_for() {
    case "$1" in
        aarch64-linux|armv7l-linux|armv6l-linux)
                           printf '%s' '\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\x00\xff\xfe\xff\xff\xff' ;;
        riscv64-linux)     printf '%s' '\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff' ;;
        powerpc64le-linux) printf '%s' '\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\x00' ;;
        s390x-linux)       printf '%s' '\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff' ;;
        mips64el-linux)    printf '%s' '\xff\xff\xff\xff\xff\xff\xff\x00\x00\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff' ;;
        i686-linux)        printf '%s' '\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff' ;;
        loongarch64-linux) printf '%s' '\xff\xff\xff\xff\xff\xff\xff\xfc\x00\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff' ;;
    esac
}

PLATFORMS="${PLATFORMS:-aarch64-linux}"
UNREGISTER="${UNREGISTER:-}"
# Where the emulators are staged so the kernel's held file description
# stays usable from every container, rootless included.  Must be a bind
# mount from the host; see the header.
INTERP_DIR="${INTERP_DIR:-/run/binfmt}"

# binfmt_misc is a filesystem that has to be mounted before the control
# files exist.  On most hosts systemd has already done it; inside a
# freshly-booted container namespace it may not be there.
if [ ! -f "$BINFMT_DIR/register" ]; then
    # Nothing mounted here.  Since Linux 6.7 each binfmt_misc mount is a
    # separate instance, so mounting one now gives us a PRIVATE table
    # that dies with this container — the registrations below would
    # appear to succeed and do nothing.  That is a silent failure, so
    # say plainly what has to be true instead.
    echo "[binfmt] no binfmt_misc mounted at $BINFMT_DIR" >&2
    echo "[binfmt] The host's instance must be bind-mounted in for" >&2
    echo "[binfmt] registrations to be visible outside this container." >&2
    echo "[binfmt] Fix on the host (once, as root), then re-run:" >&2
    echo "[binfmt]     mount -t binfmt_misc binfmt_misc $BINFMT_DIR" >&2
    echo "[binfmt] and make sure the container gets" >&2
    echo "[binfmt]     -v $BINFMT_DIR:$BINFMT_DIR" >&2
    echo "[binfmt] (docker-compose.yml already does)." >&2
    exit 1
fi

if [ -n "$UNREGISTER" ]; then
    for system in $PLATFORMS; do
        if [ -f "$BINFMT_DIR/$system" ]; then
            echo -1 > "$BINFMT_DIR/$system"
            echo "[binfmt] unregistered $system"
        else
            echo "[binfmt] $system was not registered"
        fi
    done
    exit 0
fi

mkdir -p "$INTERP_DIR"
if ! mountpoint -q "$INTERP_DIR"; then
    echo "[binfmt] WARNING: $INTERP_DIR is not a mount point, so the emulators"
    echo "[binfmt]          are being staged inside this container.  Handlers"
    echo "[binfmt]          will work from the host and rootful containers but"
    echo "[binfmt]          fail with 'Exec format error' in rootless ones."
    echo "[binfmt]          Bind-mount a host directory there (docker-compose.yml"
    echo "[binfmt]          already does: -v /run/binfmt:/run/binfmt)."
fi

registered=0
for system in $PLATFORMS; do
    qemu=$(qemu_for "$system")
    if [ -z "$qemu" ]; then
        echo "[binfmt] ERROR: unsupported platform '$system'" >&2
        echo "[binfmt] known: aarch64-linux armv7l-linux armv6l-linux riscv64-linux" >&2
        echo "[binfmt]        powerpc64le-linux s390x-linux mips64el-linux i686-linux" >&2
        echo "[binfmt]        loongarch64-linux" >&2
        exit 1
    fi

    src="/usr/local/bin/$qemu"
    if [ ! -x "$src" ]; then
        echo "[binfmt] ERROR: $src missing from this image" >&2
        exit 1
    fi

    # Stage onto the host-visible path before registering, so the fd the
    # kernel keeps is reachable from rootless containers too.
    interp="$INTERP_DIR/$qemu"
    install -D -m 0755 "$src" "$interp"

    # Already there and enabled?  Re-registering the same name is an
    # EEXIST error, so make the common `up` path idempotent.
    if [ -f "$BINFMT_DIR/$system" ]; then
        echo "[binfmt] $system already registered — leaving it alone"
        registered=$((registered + 1))
        continue
    fi

    # P = preserve argv[0] (qemu needs the real program name),
    # F = fix binary (snapshot the interpreter now; see header).
    printf ':%s:M:0:%s:%s:%s:PF' \
        "$system" "$(magic_for "$system")" "$(mask_for "$system")" "$interp" \
        > "$BINFMT_DIR/register"

    if [ -f "$BINFMT_DIR/$system" ]; then
        echo "[binfmt] registered $system -> $qemu (flags PF)"
        registered=$((registered + 1))
    else
        echo "[binfmt] ERROR: registration of $system did not take" >&2
        exit 1
    fi
done

echo "[binfmt] $registered platform(s) active; add them to the builder's"
echo "[binfmt] extra-platforms (EXTRA_PLATFORMS env) to let nix use them."
