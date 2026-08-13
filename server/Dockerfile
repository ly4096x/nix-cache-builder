# Combined Nix remote builder + binary cache server.
#
#   nix-daemon : root (required)
#   sshd       : root, accepts only `nixbuild` user
#   nix-serve  : runs as `nixbuild`  (non-root)
#   builds    : sandboxed under nixbld* system users via nix-daemon
FROM docker.io/nixos/nix:2.35.2

COPY nix.conf /etc/nix/nix.conf

# Install runtime packages via install-packages.sh so the list is in
# exactly one file (also re-used by the entrypoint self-heal step).
# The marker is written so entrypoint.sh can detect when a user's
# persistent /nix volume was populated by a previous image build.
COPY install-packages.sh /install-packages.sh
COPY build-binfmt-probes.sh /build-binfmt-probes.sh
RUN chmod +x /install-packages.sh /build-binfmt-probes.sh && \
    /install-packages.sh && \
    # Static foreign-arch binaries the entrypoint execs to report what
    # this container can emulate.  Must run here, while the channel from
    # install-packages.sh is still unpacked.
    /build-binfmt-probes.sh && \
    # Drop the nixpkgs channel source (~640 MB) from the image — the
    # closure of the packages we actually use is already in the store,
    # and install-packages.sh re-adds + re-fetches the channel at
    # runtime self-heal time when it needs to install something new.
    /root/.nix-profile/bin/nix-channel --remove nixpkgs && \
    rm -f /nix/var/nix/profiles/per-user/root/channels \
          /nix/var/nix/profiles/per-user/root/channels-*-link && \
    { nix-collect-garbage -d >/dev/null 2>&1 || true; }

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

# s6-setuidgid's getpwnam/getgrouplist abort with "No such file or
# directory" if nsswitch.conf is missing — the nixos/nix base doesn't
# ship one.  A minimal files-only nsswitch.conf is enough since the
# only users we ever resolve come from /etc/{passwd,group}.
RUN printf '%s\n' \
        'passwd: files' \
        'group: files' \
        'shadow: files' \
        'hosts: files dns' \
    > /etc/nsswitch.conf

COPY sshd_config /etc/ssh/sshd_config
COPY harmonia.toml /etc/harmonia.toml
COPY s6/ /etc/s6/sv/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /etc/s6/sv/*/run

EXPOSE 22 5000

ENTRYPOINT ["/entrypoint.sh"]
