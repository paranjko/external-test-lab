FROM ubuntu:24.04

ARG USERNAME=operator

RUN apt-get update \
    && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends \
        bash \
        binutils \
        ca-certificates \
        curl \
        git \
        jq \
        openssh-client \
        openssl \
        rsync \
        unzip \
        util-linux \
    && install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d \
    && curl --fail --location --silent --show-error \
        --output /etc/apt/keyrings/githubcli-archive-keyring.gpg \
        https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    && echo '6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b  /etc/apt/keyrings/githubcli-archive-keyring.gpg' | sha256sum --check \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && usermod --login "${USERNAME}" --home "/home/${USERNAME}" --move-home ubuntu \
    && install -d -o "${USERNAME}" -g ubuntu -m 0700 "/home/${USERNAME}/.ssh" \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"
