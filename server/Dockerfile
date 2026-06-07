# Combined Nix remote builder + binary cache server.
#
#   nix-daemon : root (required)
#   sshd       : root, accepts only `nixbuild` user
#   nix-serve  : runs as `nixbuild`  (non-root)
#   builds    : sandboxed under nixbld* system users via nix-daemon
FROM docker.io/nixos/nix:2.24.10

COPY nix.conf /etc/nix/nix.conf

# Pin to a known-good channel snapshot via nix-env -iA on the bundled
# `nixpkgs` channel that ships with the base image.
RUN nix-env -iA \
        nixpkgs.openssh \
        nixpkgs.nix-serve \
        nixpkgs.bash \
        nixpkgs.shadow \
        nixpkgs.util-linux \
        nixpkgs.coreutils \
        nixpkgs.gnused \
        nixpkgs.gnugrep \
    && nix-collect-garbage -d >/dev/null 2>&1 || true

# Expose nix-installed binaries on the global PATH so non-interactive ssh
# sessions (sshd execs nix-daemon for ssh-ng builds) can find them.
RUN mkdir -p /usr/local/bin && \
    for bin in /root/.nix-profile/bin/*; do \
        ln -sf "$bin" "/usr/local/bin/$(basename "$bin")"; \
    done

# The base image symlinks /etc/{passwd,group,shadow} into the read-only nix
# store; break them into writable files before adding our build user.
RUN for f in passwd group shadow; do \
        if [ -L /etc/$f ]; then \
            cp -L /etc/$f /etc/$f.real && rm -f /etc/$f && mv /etc/$f.real /etc/$f; \
        fi; \
    done && \
    groupadd -r nixbuild && \
    # Use /usr/local/bin/bash (symlink to the nix-installed bash from the
    # step above); /bin/bash doesn't exist in this base image.
    useradd -r -g nixbuild -d /home/nixbuild -s /usr/local/bin/bash -m nixbuild && \
    # useradd -r leaves the password field as `!` (locked).  sshd refuses
    # locked accounts even with pubkey-only auth, so replace `!` with `*`
    # — account active, no password possible, key auth still works.
    sed -i 's|^nixbuild:[^:]*:|nixbuild:*:|' /etc/shadow && \
    mkdir -p /home/nixbuild/.ssh && \
    chown -R nixbuild:nixbuild /home/nixbuild && \
    chmod 700 /home/nixbuild/.ssh && \
    # OpenSSH refuses to start without a sshd privsep user/account.
    groupadd -r sshd && \
    useradd -r -g sshd -d /var/empty -s /sbin/nologin -M sshd

# sshd runtime dirs
RUN mkdir -p /etc/ssh /var/run/sshd /var/empty && \
    chmod 711 /var/empty

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22 5000

ENTRYPOINT ["/entrypoint.sh"]
