# NixOS-flavoured client used to verify the server is both building and
# caching as expected.  Uses the same nixos/nix base image so a real `nix`
# binary drives the test (rather than curl-only smoke tests).
FROM docker.io/nixos/nix:2.24.10

RUN nix-env -iA \
        nixpkgs.openssh \
        nixpkgs.curl \
        nixpkgs.netcat \
        nixpkgs.jq \
        nixpkgs.bash \
        nixpkgs.coreutils \
        nixpkgs.gnused \
        nixpkgs.gnugrep \
        nixpkgs.gawk \
    && nix-collect-garbage -d >/dev/null 2>&1 || true

RUN mkdir -p /usr/local/bin && \
    for bin in /root/.nix-profile/bin/*; do \
        ln -sf "$bin" "/usr/local/bin/$(basename "$bin")"; \
    done

RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

COPY entrypoint.sh /entrypoint.sh
COPY verify.sh /verify.sh
RUN chmod +x /entrypoint.sh /verify.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/verify.sh"]
