FROM bats/bats:1.14.0

RUN apk add --no-cache bash coreutils curl findutils jq openssl py3-jsonschema python3

COPY net-deployment-runbook /workspace/net-deployment-runbook
COPY schema /workspace/schema
COPY bootstrap /workspace/bootstrap
WORKDIR /workspace/net-deployment-runbook

ENTRYPOINT ["bats"]
