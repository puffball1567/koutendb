# PRK CRUD Demo

This runnable demo combines Prologue, React, and KoutenDB. It uses the same UI
and REST contract as the REKT demo, while the API is implemented in Nim with
Prologue and KoutenDB's public Nim client API.

JSON tasks are stored in category rings. Tags rank related tasks only inside
the selected category ring. The demo covers create, list, point read, update,
delete, ring relocation, and related-data retrieval against an authenticated
persistent KoutenDB node.

The interactive stack uses a 50 ms server slow tick. The Prologue API selects
`wamApplied`, so a successful mutation response is already visible to ring
reads.

## Run

From the KoutenDB repository root:

```sh
docker compose -f examples/prk-crud/compose.yml up -d --build --wait
```

Open <http://localhost:18081>.

## Data Locality

The category field controls KoutenDB placement. `general` uses `demo/tasks`,
while categories such as `engineering` use `demo/tasks/engineering`. Tags are
payload metadata evaluated after that ring has narrowed the candidate set.

The Related view exposes the actual ring and candidate count used by the
query. Changing a category relocates the task to its new ring instead of
leaving placement and metadata out of sync.

## Verify CRUD and Locality

```sh
docker compose -f examples/prk-crud/compose.yml --profile test run --rm smoke
```

The shared smoke contract covers CRUD, category ring placement, tag-ranked
related reads, single-ring candidate scope, category relocation, and deletion.
Running it against both demos verifies that the Node driver and public Nim API
expose equivalent application behavior.

## Stop

```sh
docker compose -f examples/prk-crud/compose.yml down
```

Add `-v` only when you also want to remove the persistent demo data.

## HTTP API

| Method | Path | Operation |
| --- | --- | --- |
| `GET` | `/api/meta` | List category and ring metadata |
| `GET` | `/api/tasks` | Read tasks across the configured category rings |
| `GET` | `/api/tasks/:id` | Point-read one KoutenDB ID |
| `GET` | `/api/tasks/:id/related` | Rank related tasks inside the task's category ring |
| `POST` | `/api/tasks` | Create a JSON task |
| `PUT` | `/api/tasks/:id` | Replace a task, relocating it when its category changes |
| `DELETE` | `/api/tasks/:id` | Delete one task |

REST responses expose KoutenDB IDs as URL-safe
`parent_epoch_seq_tWrite` strings. Each API converts that representation back
to the native KoutenDB ID before point operations.

This is an integration demo, not a production deployment template. Production
deployments should provide managed secrets, TLS, request authentication,
resource limits, backups, and application-specific authorization.
