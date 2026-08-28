FROM nimlang/nim:2.2.10 AS core

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libsodium-dev openssl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/koutendb-deps
RUN nimble install -y nimsodium

WORKDIR /src
COPY koutendb.nimble config.nims ./
COPY include ./include
COPY scripts/build_capi.sh ./scripts/build_capi.sh
COPY src ./src
RUN ./scripts/build_capi.sh

FROM node:20-bookworm-slim AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates g++ make python3 libsodium23 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/koutendb
COPY --from=core /src/include ./include
COPY --from=core /src/lib ./lib

ENV KOUTENDB_CORE_DIR=/opt/koutendb
ENV KOUTENDB_LIB_DIR=/opt/koutendb/lib
ENV LD_LIBRARY_PATH=/opt/koutendb/lib

WORKDIR /app
COPY examples/rekt-crud/api/package*.json ./
RUN npm ci
COPY examples/rekt-crud/api/tsconfig.json ./
COPY examples/rekt-crud/api/src ./src
RUN npm run build

FROM node:20-bookworm-slim AS runtime

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libsodium23 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 10001 app

WORKDIR /opt/koutendb
COPY --from=core /src/lib ./lib

WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=build /app/package.json ./package.json

ENV NODE_ENV=production
ENV LD_LIBRARY_PATH=/opt/koutendb/lib
ENV PORT=3000
USER app
EXPOSE 3000
CMD ["node", "dist/server.js"]
