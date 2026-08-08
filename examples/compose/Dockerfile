FROM nimlang/nim:2.2.10

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libsodium-dev openssl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/koutendb-deps
RUN nimble install -y nimsodium

WORKDIR /src
COPY koutendb.nimble config.nims ./

COPY src ./src
RUN nim c -d:ssl -d:release --nimcache:/tmp/nimcache_koutend -o:/usr/local/bin/koutend src/koutend.nim \
 && nim c -d:ssl -d:release --nimcache:/tmp/nimcache_koutencli -o:/usr/local/bin/koutencli src/koutencli.nim

WORKDIR /data
ENTRYPOINT ["koutend"]
