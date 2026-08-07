# Query Safety

KoutenDB does not execute SQL, so its query-safety surface is different from a
SQL database.

The two important pieces are:

- prepared selections for projection;
- typed filter builders for read filters.

Both are designed to avoid string-concatenated query text while keeping
KoutenDB's read path centered on a `ring` or `stellar` coordinate.

## Prepared Selections

Selections are GraphQL-style projections over JSON payloads:

```nim
let fields = prepareSelection("{ title author { name } }")
let first = db.query(firstId, fields)
let second = db.query(secondId, fields)
```

`prepareSelection` validates and parses the selection once. Embedded reads reuse
the parsed tree directly. Cluster nodes also keep a bounded cache of validated
selection trees. The server cache is bounded by both entry count and the total
source bytes retained, and very large selection strings are rejected before they
can be cached.

The selection grammar contains field names only. Payload values are not
interpolated into it.

## Typed Filter Builders

Filters are still represented as JSON objects internally and on the wire. That
keeps the CLI, C ABI, and existing drivers compatible.

For application code, KoutenDB also provides a builder so callers do not need to
construct filter JSON by string concatenation:

```nim
let filter = koutenFilter().eq("status", "draft").eq("kind", "order")

let page = db.readRing("docs/japan", defaultReadOptions().withFilter(filter))
```

The same filter can be used with stellar reads:

```nim
let page = db.readStellar("commerce/order/A-001",
  defaultStellarOptions().withFilter(koutenFilter().eq("kind", "shop")))
```

ID reads can also be built without manually stringifying the ID:

```nim
let page = db.readRing("users", defaultReadOptions().withFilter(
  koutenFilter().id(userId)))
```

Supported builder values:

- strings;
- integers;
- floats;
- booleans;
- explicit `JsonNode` values;
- KoutenDB IDs through `id(id)`.

## Scope Comes First

The filter builder is not intended to turn KoutenDB into an ad-hoc global query
engine.

KoutenDB's read model remains:

1. choose a `ring` or `stellar` coordinate;
2. optionally narrow with `subring`;
3. apply typed filters inside that local scope;
4. project only the requested fields.

This keeps query safety aligned with the main KoutenDB idea: avoid unrelated
working sets before downstream work begins.

## Server-Side Cost Guards

`koutend` also enforces bounded network query work. `RETRIEVE` requests have a
maximum result budget and a maximum vector scan count. If a request crosses
those bounds, the server returns a stable `ERR bad-request` instead of keeping
the single-threaded server busy indefinitely.

`LISTR` pages are also bounded to 10,000 records per request. Clients should
use the returned cursor instead of requesting an unbounded ring response.
Accepted sockets have both receive and send deadlines, so a client that stops
mid-request or stops reading a response cannot hold the server loop forever.

The normal fix is not to raise the cap first. Prefer a `ring`, `stellar`, child
scope, or narrower retrieval plan so KoutenDB can reduce the candidate set before
scoring. This turns unsafe broad scans into an observable tuning problem instead
of hiding them behind a slow global query.

## Compatibility

These two forms are equivalent:

```nim
let a = db.readRing("docs", KoutenReadOptions(
  filter: %*{"status": "draft"},
  selection: "{ title }"))

let b = db.readRing("docs", defaultReadOptions()
  .withFilter(koutenFilter().eq("status", "draft")))
```

The builder-produced filter is a defensive JSON object copy. It can be passed
through the same API paths that already accept `JsonNode` filters.
