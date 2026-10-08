FROM golang:1.27-bookworm AS build
WORKDIR /src/gonkactl-test
COPY go.mod go.sum ./
RUN go mod download
COPY . ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/gonkactl-test ./cmd

FROM node:24-alpine AS allure
WORKDIR /src/gonkactl-test/report
COPY report/package.json report/package-lock.json ./
RUN npm ci --ignore-scripts
COPY report ./

FROM docker:28.4.0-dind
RUN apk add --no-cache bash git libgcc libstdc++
COPY --from=build /usr/local/go /usr/local/go
ENV PATH="/usr/local/go/bin:${PATH}"
COPY --from=build /out/gonkactl-test /usr/local/bin/gonkactl-test
COPY --from=allure /usr/local/bin/node /usr/local/bin/node
COPY --from=allure /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=allure /src/gonkactl-test/report /opt/gonkactl-test/report
ENV GONKACTL_TEST_REPORT_DIR=/opt/gonkactl-test/report
COPY docker-entrypoint.sh /usr/local/bin/gonkactl-test-entrypoint
RUN chmod 0755 /usr/local/bin/gonkactl-test-entrypoint
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/gonkactl-test-entrypoint"]
CMD ["gonkactl-test", "release"]
