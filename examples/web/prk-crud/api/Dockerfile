FROM nimlang/nim:2.2.10 AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libsodium-dev openssl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/koutendb-deps
RUN nimble install -y nimsodium prologue@0.6.10

WORKDIR /src
COPY koutendb.nimble config.nims ./
COPY src ./src
COPY examples/web/prk-crud/api/app.nim ./examples/web/prk-crud/api/app.nim
RUN nim c -d:release -d:ssl -d:usestd --path:/src/src \
  --nimcache:/tmp/nimcache_prk -o:/usr/local/bin/prk-api \
  examples/web/prk-crud/api/app.nim

FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl libsodium23 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 10001 app

COPY --from=build /usr/local/bin/prk-api /usr/local/bin/prk-api
ENV PORT=3000
USER app
EXPOSE 3000
CMD ["prk-api"]
