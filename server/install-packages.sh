#!/usr/bin/env bash
# Single source of truth for the server's runtime package list.
#
# Run from two places:
#   - the Dockerfile, at image build, into the image's nix profile
#   - entrypoint.sh, at container start, if a marker comparison shows
#     the user's persistent /nix volume was populated by an older image
#     (otherwise the /usr/local/bin symlinks point at store paths that
#     don't exist in the volume, and tools like supervisord 404)
#
# Adding or removing a package means editing only this file.
set -euo pipefail

# Make sure the `nixpkgs` channel is subscribed and unpacked before
# nix-env tries to resolve attributes from it.
#
# The base image leaves the channel subscribed but never fetched, and
# the Dockerfile deletes the channel after image build (to drop
# ~640 MB of nixpkgs source from the image).  Re-adding is idempotent
# so this works in all three cases: image build, runtime self-heal
# right after a fresh container start, and runtime self-heal after an
# image upgrade.
/root/.nix-profile/bin/nix-channel --add \
    https://channels.nixos.org/nixpkgs-unstable nixpkgs >&2
/root/.nix-profile/bin/nix-channel --update >&2

exec /root/.nix-profile/bin/nix-env -iA \
    nixpkgs.openssh \
    nixpkgs.nix-serve \
    nixpkgs.python3Packages.supervisor \
    nixpkgs.procps \
    nixpkgs.bash \
    nixpkgs.shadow \
    nixpkgs.util-linux \
    nixpkgs.coreutils \
    nixpkgs.gnused \
    nixpkgs.gnugrep
