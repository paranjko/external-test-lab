FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends openssh-client \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir ansible-core==2.18.6
ENV ANSIBLE_HOME=/tmp/ansible ANSIBLE_SSH_CONTROL_PATH_DIR=/tmp/ansible/cp
WORKDIR /ansible
