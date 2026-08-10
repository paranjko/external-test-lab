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
        sudo \
        unzip \
        util-linux \
    && usermod --login "${USERNAME}" --home "/home/${USERNAME}" --move-home ubuntu \
    && printf '%s ALL=(root) NOPASSWD:ALL\n' "${USERNAME}" >"/etc/sudoers.d/${USERNAME}" \
    && chmod 0440 "/etc/sudoers.d/${USERNAME}" \
    && install -d -o "${USERNAME}" -g ubuntu -m 0700 "/home/${USERNAME}/.ssh" \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"

# The build context is filtered by .dockerignore before it reaches Docker.
# This immutable copy seeds the isolated workspace volume on container creation.
COPY --chown=${USERNAME}:ubuntu . /opt/runbook-source
