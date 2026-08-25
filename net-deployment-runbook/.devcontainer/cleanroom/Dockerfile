FROM ubuntu:24.04

ARG USERNAME=operator

RUN apt-get update \
    && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        jq \
        openssh-client \
        openssl \
        rsync \
        unzip \
        util-linux \
    && usermod --login "${USERNAME}" --home "/home/${USERNAME}" --move-home ubuntu \
    && install -d -o "${USERNAME}" -g ubuntu -m 0700 "/home/${USERNAME}/.ssh" \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"
