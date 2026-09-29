# Protocol-test tools only; the pinned production TMKMS binary is unchanged.
FROM ghcr.io/product-science/tmkms-softsign-with-keygen:0.2.15@sha256:c3b6c4aaa73e93944dda4f08db8edd1a48544ad35d740cfca2dd8f3d9835aa21
USER root
COPY tmkms-boundary-packages.txt /tmp/tmkms-boundary-packages.txt
RUN sha256sum /usr/local/cargo/bin/tmkms >/tmp/tmkms.sha256 \
    && apt-get update \
    && xargs -r apt-get install -y --no-install-recommends </tmp/tmkms-boundary-packages.txt \
    && sha256sum -c /tmp/tmkms.sha256 \
    && rm -rf /var/lib/apt/lists/* /tmp/tmkms.sha256
COPY test-tmkms-recovery-boundary.sh /test-tmkms-recovery-boundary.sh
ENTRYPOINT ["bash", "/test-tmkms-recovery-boundary.sh"]
