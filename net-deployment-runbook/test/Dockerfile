FROM bats/bats:1.14.0

RUN apk add --no-cache bash coreutils curl findutils jq openssl py3-jsonschema python3

WORKDIR /workspace
COPY . /workspace

ENTRYPOINT ["bats"]
