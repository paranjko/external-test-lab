FROM ubuntu:24.04

RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        openssh-server \
        sudo \
    && install -d -m 0755 /run/sshd /root/.ssh \
    && printf '%s\n' \
        'PermitRootLogin prohibit-password' \
        'PasswordAuthentication no' \
        'KbdInteractiveAuthentication no' \
        'UsePAM no' \
        'AllowTcpForwarding no' \
        'X11Forwarding no' \
        > /etc/ssh/sshd_config.d/gonka-node-host.conf \
    && rm -rf /var/lib/apt/lists/*
