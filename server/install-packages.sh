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

# Make sure the base image's `nixpkgs` channel is actually unpacked
# before nix-env tries to resolve attributes from it.  The image leaves
# the channel subscribed but with no fetched contents, so the very
# first nix-env -iA in a fresh root profile would 404 with
# "attribute 'nixpkgs' ... not found".
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
