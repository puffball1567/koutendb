FROM nimlang/nim:2.2.10 AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc libsodium-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/koutendb-deps
RUN nimble install -y nimsodium

WORKDIR /build
COPY koutendb.nimble config.nims ./
COPY src ./src
RUN nim c -d:ssl -d:release --nimcache:/tmp/nimcache_koutend \
      -o:/out/koutend src/koutend.nim \
 && nim c -d:ssl -d:release --nimcache:/tmp/nimcache_kouten \
      -o:/out/kouten src/koutencli.nim

FROM debian:trixie-slim AS runtime

ARG VCS_REF="unknown"
ARG VERSION="dev"
ENV DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.title="KoutenDB" \
      org.opencontainers.image.description="Locality-first document and vector database" \
      org.opencontainers.image.source="https://github.com/puffball1567/koutendb" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0"

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libsodium23 openssl \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 10001 koutendb \
 && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /var/lib/koutendb \
      --shell /usr/sbin/nologin koutendb \
 && install -d -o koutendb -g koutendb -m 0750 /var/lib/koutendb /etc/koutendb

COPY --from=build /out/koutend /usr/local/bin/koutend
COPY --from=build /out/kouten /usr/local/bin/kouten
RUN ln -s /usr/local/bin/kouten /usr/local/bin/koutencli

USER 10001:10001
WORKDIR /var/lib/koutendb
VOLUME ["/var/lib/koutendb"]
EXPOSE 7301
STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/local/bin/koutend"]
