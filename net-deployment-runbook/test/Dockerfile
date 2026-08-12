FROM bats/bats:1.14.0

RUN apk add --no-cache bash coreutils curl jq python3

WORKDIR /workspace
COPY . /workspace

ENTRYPOINT ["bats"]
