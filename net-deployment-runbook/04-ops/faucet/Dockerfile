ARG INFERENCED_IMAGE
FROM ${INFERENCED_IMAGE} AS inferenced

FROM python:3.12-slim
COPY --from=inferenced /usr/bin/inferenced /usr/local/bin/inferenced
COPY --from=inferenced /lib/ld-musl-x86_64.so.1 /lib/ld-musl-x86_64.so.1
COPY --from=inferenced /usr/lib/libgcc_s.so.1 /usr/lib/libgcc_s.so.1
RUN ln -s ld-musl-x86_64.so.1 /lib/libc.musl-x86_64.so.1
WORKDIR /app
COPY faucet.py /app/faucet.py
EXPOSE 18081
CMD ["python3", "/app/faucet.py"]
