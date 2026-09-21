FROM nimlang/nim:2.2.10 AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git libsodium-dev openssl \
 && rm -rf /var/lib/apt/lists/*
ARG JAZZY_REV=d45d49d07a6d130b56c1070f723cf668094e276b
RUN git clone https://github.com/canermastan/jazzy-framework.git /deps/jazzy \
 && git -C /deps/jazzy checkout --detach "$JAZZY_REV"
WORKDIR /deps/jazzy
RUN nimble --useSystemNim install -y --depsOnly \
 && nimble --useSystemNim install -y nimsodium@0.2.0

WORKDIR /src
COPY src ./src
COPY examples/web/jazzy-crud/api/app.nim ./examples/web/jazzy-crud/api/app.nim
RUN nim c --skipParentCfg:on --mm:atomicArc --threads:on --panics:on \
  -d:useMalloc -d:release -d:ssl --path:/src/src --path:/deps/jazzy/src \
  --nimcache:/tmp/nimcache_jazzy -o:/usr/local/bin/jazzy-api \
  examples/web/jazzy-crud/api/app.nim

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl libsodium23 libsqlite3-0 libpq5 libssl3 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 10001 app
COPY --from=build /usr/local/bin/jazzy-api /usr/local/bin/jazzy-api
ENV PORT=3000 APP_ENV=production DEV_UI_ENABLED=false LOG_LEVEL=NONE MAX_UPLOAD_SIZE=1
USER app
EXPOSE 3000
CMD ["jazzy-api"]
