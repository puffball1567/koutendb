# REKT CRUD Demo

This runnable demo combines React, Express, KoutenDB, and TypeScript. It stores
JSON tasks in category rings, then uses tags to rank related tasks inside the
selected category. It exercises create, list, point read, update, delete, ring
relocation, and related-data retrieval through the official `koutendb` npm
driver.

The browser never receives KoutenDB credentials. React calls the Express API,
and Express owns the authenticated KoutenDB connection.

The interactive stack uses a 50 ms server slow tick. Because the current
published Node driver uses accepted acknowledgements, the REST API also waits
for each mutation to become ring-visible before returning success.

## Run

From the KoutenDB repository root:

```sh
docker compose -f examples/rekt-crud/compose.yml up -d --build --wait
```

Open <http://localhost:18080>.

To use non-demo credentials:

```sh
KOUTEN_PASSWORD='replace-me' KOUTEN_SECRET_KEY='replace-me-too' \
  docker compose -f examples/rekt-crud/compose.yml up -d --build --wait
```

## Data Locality

The form separates placement from evaluation:

- A category selects a KoutenDB ring. `general` maps to `demo/tasks` for
  backward compatibility; other categories map to rings such as
  `demo/tasks/engineering`.
- Tags remain payload metadata. They rank related tasks only after the
  category ring has narrowed the candidate set.
- Changing a task's category relocates it to the new ring and removes the old
  record.

The Related view displays the ring that was read and the number of candidates
evaluated. A task in `engineering` therefore does not require a scan of
`operations`, even when both tasks share a tag.

## Verify CRUD and Locality

```sh
docker compose -f examples/rekt-crud/compose.yml --profile test run --rm smoke
```

The smoke test covers CRUD, category ring placement, tag-ranked related reads,
single-ring candidate scope, category relocation, and deletion.

## Stop

```sh
docker compose -f examples/rekt-crud/compose.yml down
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
