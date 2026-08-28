# Web Integration Demos

These runnable Docker Compose stacks show how an application can use KoutenDB
without exposing database credentials to the browser.

- [REKT CRUD](rekt-crud/README.md): React, Express, KoutenDB, and TypeScript
  through the published `koutendb` npm driver.
- [PRK CRUD](prk-crud/README.md): Prologue, React, and KoutenDB through the
  public Nim client API.

Both stacks expose the same task application and HTTP contract. Categories
select ring placement, while tags rank related records only after the selected
ring has narrowed the candidate set. This makes the locality boundary visible
in a normal CRUD application.

Run both integration contracts from the repository root:

```sh
scripts/web_crud_demo_smoke.sh
```

Each demo README also documents how to start its interactive UI independently.
These examples are evaluation environments, not production deployment
templates.
