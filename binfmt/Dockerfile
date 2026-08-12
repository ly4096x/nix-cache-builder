# One-shot binfmt_misc registrar.
#
# Separate from the builder image on purpose: registering handlers needs
# CAP_SYS_ADMIN, and we do not want the long-lived nix-builder (which
# accepts ssh connections) running privileged.  This container starts,
# registers, and exits; the handlers persist because they are written
# with the F flag (see register-binfmt.sh).
FROM docker.io/nixos/nix:2.34.7

# pkgsStatic.qemu-user: the emulators must be STATICALLY linked.  With
# the F flag the kernel snapshots only the interpreter file itself — a
# dynamic qemu would still try to resolve its loader and libc in the
# *target* mount namespace at exec time, where the nix store holding
# them does not exist.
RUN nix-channel --add https://channels.nixos.org/nixpkgs-unstable nixpkgs && \
    nix-channel --update && \
    nix-env -iA \
        nixpkgs.pkgsStatic.qemu-user \
        nixpkgs.util-linux \
        nixpkgs.bash \
        nixpkgs.coreutils && \
    nix-channel --remove nixpkgs && \
    rm -f /nix/var/nix/profiles/per-user/root/channels \
          /nix/var/nix/profiles/per-user/root/channels-*-link && \
    { nix-collect-garbage -d >/dev/null 2>&1 || true; }

RUN mkdir -p /usr/local/bin && \
    for bin in /root/.nix-profile/bin/*; do \
        ln -sf "$bin" "/usr/local/bin/$(basename "$bin")"; \
    done

COPY register-binfmt.sh /register-binfmt.sh
RUN chmod +x /register-binfmt.sh

ENTRYPOINT ["/register-binfmt.sh"]
