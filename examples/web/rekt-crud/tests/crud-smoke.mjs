import assert from "node:assert/strict";

const base = process.env.BASE_URL ?? "http://web:8080/api";
const marker = `smoke-${Date.now()}`;

const meta = await request("/meta");
assert.equal(meta.ring, "demo/tasks");
assert.ok(meta.categories.includes("engineering"));
assert.ok(meta.categories.includes("operations"));

const created = await request("/tasks", {
  method: "POST",
  body: JSON.stringify({
    title: marker,
    category: "engineering",
    tags: ["api", "docker"],
  }),
}, 201);
assert.equal(created.title, marker);
assert.equal(created.completed, false);
assert.equal(created.category, "engineering");
assert.deepEqual(created.tags, ["api", "docker"]);

const relatedPeer = await request("/tasks", {
  method: "POST",
  body: JSON.stringify({
    title: `${marker}-related`,
    category: "engineering",
    tags: ["api", "rag"],
  }),
}, 201);

const distantPeer = await request("/tasks", {
  method: "POST",
  body: JSON.stringify({
    title: `${marker}-distant`,
    category: "operations",
    tags: ["api"],
  }),
}, 201);

const listed = await request("/tasks");
assert.ok(listed.items.some((task) => task.id === created.id));
assert.ok(listed.items.some((task) => task.id === relatedPeer.id));
assert.ok(listed.items.some((task) => task.id === distantPeer.id));

const fetched = await request(`/tasks/${encodeURIComponent(created.id)}`);
assert.equal(fetched.title, marker);

const related = await request(`/tasks/${encodeURIComponent(created.id)}/related`);
assert.equal(related.scope.ring, "demo/tasks/engineering");
assert.equal(related.scope.categoriesScanned, 1);
assert.equal(related.scope.candidates, 1);
assert.ok(related.items.some((task) => task.id === relatedPeer.id));
assert.ok(!related.items.some((task) => task.id === distantPeer.id));
assert.deepEqual(related.items[0].sharedTags, ["api"]);

const relocated = await request(`/tasks/${encodeURIComponent(created.id)}`, {
  method: "PUT",
  body: JSON.stringify({
    title: `${marker}-updated`,
    completed: true,
    category: "operations",
    tags: ["docker", "infra"],
  }),
});
assert.equal(relocated.completed, true);
assert.equal(relocated.title, `${marker}-updated`);
assert.equal(relocated.category, "operations");
assert.notEqual(relocated.id, created.id);
await request(`/tasks/${encodeURIComponent(created.id)}`, {}, 404);

const relocatedRelated = await request(`/tasks/${encodeURIComponent(relocated.id)}/related`);
assert.equal(relocatedRelated.scope.ring, "demo/tasks/operations");
assert.ok(relocatedRelated.items.some((task) => task.id === distantPeer.id));

await request(`/tasks/${encodeURIComponent(relocated.id)}`, { method: "DELETE" }, 204);
await request(`/tasks/${encodeURIComponent(relatedPeer.id)}`, { method: "DELETE" }, 204);
await request(`/tasks/${encodeURIComponent(distantPeer.id)}`, { method: "DELETE" }, 204);
await request(`/tasks/${encodeURIComponent(relocated.id)}`, {}, 404);
const afterDelete = await request("/tasks");
assert.ok(!afterDelete.items.some((task) => task.id === relocated.id));

console.log("CRUD/locality smoke passed: category rings, tags, related scope, relocation, delete");

async function request(path, init = {}, expected = 200) {
  const response = await fetch(`${base}${path}`, {
    ...init,
    headers: { "Content-Type": "application/json", ...init.headers },
  });
  assert.equal(response.status, expected, `${init.method ?? "GET"} ${path}`);
  return response.status === 204 ? undefined : response.json();
}
