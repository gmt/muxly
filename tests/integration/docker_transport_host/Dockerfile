FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-server ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/sh muxlytest \
    && passwd -d muxlytest \
    && mkdir -p /run/sshd /home/muxlytest/.ssh /etc/ssh/sshd_config.d \
    && chown -R muxlytest:muxlytest /home/muxlytest/.ssh \
    && chmod 700 /home/muxlytest/.ssh

RUN printf '%s\n' \
    'PasswordAuthentication no' \
    'PubkeyAuthentication yes' \
    'PermitRootLogin no' \
    'UsePAM no' \
    'AuthorizedKeysFile .ssh/authorized_keys' \
    > /etc/ssh/sshd_config.d/muxlytest.conf

COPY entrypoint.sh /usr/local/bin/muxly-docker-sshd-entrypoint
RUN chmod +x /usr/local/bin/muxly-docker-sshd-entrypoint

ENTRYPOINT ["/usr/local/bin/muxly-docker-sshd-entrypoint"]
