import express, { type NextFunction, type Request, type Response } from "express";
import {
  KoutenDb,
  KoutenDbError,
  formatKoutenId,
  parseKoutenId,
  type ReadRingItem,
} from "koutendb";

const port = readPort(process.env.PORT, 3000);
const ring = process.env.KOUTEN_RING ?? "demo/tasks";
const peers = process.env.KOUTEN_PEERS ?? "koutendb:7301";
const categories = ["general", "planning", "engineering", "research", "operations"] as const;
type Category = (typeof categories)[number];

const db = KoutenDb.connect(peers, {
  username: process.env.KOUTEN_USER ?? "demo",
  password: process.env.KOUTEN_PASSWORD ?? "demo-password",
  secretKey: process.env.KOUTEN_SECRET_KEY ?? "demo-secret-key",
  galaxy: process.env.KOUTEN_GALAXY ?? "rekt-demo",
});

interface TaskPayload {
  title: string;
  completed: boolean;
  category: Category;
  tags: string[];
  createdAt: string;
  updatedAt: string;
}

interface Task extends TaskPayload {
  id: string;
}

class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

const app = express();
app.disable("x-powered-by");
app.use(express.json({ limit: "32kb" }));

app.get("/health", (_request, response) => {
  response.json({ status: "ok", stack: "REKT", ring });
});

app.get("/meta", (_request, response) => {
  response.json({ ring, categories });
});

app.get("/tasks", (_request, response) => {
  const items = categories
    .flatMap((category) => readCategoryTasks(category))
    .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
  response.json({ items, count: items.length });
});

app.get("/tasks/:id/related", (request, response) => {
  const task = readTask(request.params.id);
  const scopeRing = categoryRing(task.category);
  const candidates = db.readRing(scopeRing, { limit: 100, rsort: "write" })
    .items.map((item) => taskFromItem(item, task.category))
    .filter((candidate) => candidate.id !== task.id);
  const related = candidates
    .map((candidate) => {
      const sharedTags = candidate.tags.filter((tag) => task.tags.includes(tag));
      return { ...candidate, sharedTags, score: sharedTags.length };
    })
    .sort((left, right) => right.score - left.score || right.updatedAt.localeCompare(left.updatedAt))
    .slice(0, 6);
  response.json({
    task,
    scope: { ring: scopeRing, candidates: candidates.length, categoriesScanned: 1 },
    items: related,
  });
});

app.get("/tasks/:id", (request, response) => {
  response.json(readTask(request.params.id));
});

app.post("/tasks", async (request, response) => {
  const now = new Date().toISOString();
  const payload: TaskPayload = {
    title: requireTitle(request.body?.title),
    completed: readCompleted(request.body?.completed, false),
    category: readCategory(request.body?.category, "general"),
    tags: readTags(request.body?.tags),
    createdAt: now,
    updatedAt: now,
  };
  const id = db.putJson(categoryRing(payload.category), payload);
  const idText = publicId(formatKoutenId(id));
  await waitForRingTask(payload.category, idText, (task) => task?.updatedAt === payload.updatedAt);
  response.status(201).json({ id: idText, ...payload });
});

app.put("/tasks/:id", async (request, response) => {
  const current = readTask(request.params.id);
  const payload: TaskPayload = {
    title: requireTitle(request.body?.title),
    completed: readCompleted(request.body?.completed, current.completed),
    category: readCategory(request.body?.category, current.category),
    tags: request.body?.tags === undefined ? current.tags : readTags(request.body.tags),
    createdAt: current.createdAt,
    updatedAt: new Date().toISOString(),
  };
  let idText = request.params.id;
  if (payload.category === current.category) {
    db.updateJson(parsePublicId(idText), payload);
  } else {
    const relocated = db.putJson(categoryRing(payload.category), payload);
    const relocatedId = publicId(formatKoutenId(relocated));
    await waitForRingTask(payload.category, relocatedId,
      (task) => task?.updatedAt === payload.updatedAt);
    db.remove(parsePublicId(idText));
    await waitForRingTask(current.category, idText, (task) => task === undefined);
    idText = relocatedId;
  }
  await waitForRingTask(payload.category, idText, (task) => task?.updatedAt === payload.updatedAt);
  response.json({ id: idText, ...payload });
});

app.delete("/tasks/:id", async (request, response) => {
  const id = parsePublicId(request.params.id);
  const current = readTask(request.params.id);
  db.remove(id);
  await waitForRingTask(current.category, request.params.id, (task) => task === undefined);
  response.status(204).end();
});

app.use((_request, _response, next) => {
  next(new HttpError(404, "route not found"));
});

app.use((error: unknown, _request: Request, response: Response, _next: NextFunction) => {
  const status =
    error instanceof HttpError ? error.status
      : error instanceof KoutenDbError && error.kind === "invalid_id" ? 400
        : error instanceof KoutenDbError && error.kind === "not_found" ? 404
          : 500;
  const message = error instanceof Error ? error.message : "unexpected error";
  if (status === 500) console.error(error);
  response.status(status).json({ error: message });
});

const server = app.listen(port, "0.0.0.0", () => {
  console.log(`REKT API listening on ${port}; KoutenDB ring=${ring}`);
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    server.close(() => {
      db.close();
      process.exit(0);
    });
  });
}

function readTask(rawId: string): Task {
  const id = parsePublicId(rawId);
  const raw = db.getString(id);
  if (raw === null) throw new HttpError(404, "task not found");
  return { id: rawId, ...parseTask(raw) };
}

function taskFromItem(item: ReadRingItem, fallbackCategory: Category): Task {
  if (item.codec !== "json" || typeof item.payload !== "object" || item.payload === null) {
    throw new HttpError(500, `ring ${ring} contains a non-JSON task`);
  }
  return { id: publicId(item.rawId), ...normalizeTask(item.payload, fallbackCategory) };
}

function readCategoryTasks(category: Category): Task[] {
  const page = db.readRing(categoryRing(category), { limit: 500, rsort: "write" });
  return page.items.map((item) => taskFromItem(item, category));
}

function categoryRing(category: Category): string {
  return category === "general" ? ring : `${ring}/${category}`;
}

function publicId(rawId: string): string {
  return rawId.replaceAll(":", "_");
}

function parsePublicId(value: string) {
  const parts = value.split("_");
  if (parts.length !== 4) throw new HttpError(400, "invalid task id");
  return parseKoutenId(parts.join(":"));
}

async function waitForRingTask(
  category: Category,
  id: string,
  matches: (task: Task | undefined) => boolean,
  timeoutMs = 2_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  do {
    const task = readCategoryTasks(category).find((item) => item.id === id);
    if (matches(task)) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  } while (Date.now() <= deadline);
  throw new HttpError(503, "KoutenDB mutation was accepted but not visible before the API deadline");
}

function parseTask(raw: string): TaskPayload {
  try {
    return normalizeTask(JSON.parse(raw), "general");
  } catch {
    throw new HttpError(500, `ring ${ring} contains invalid JSON`);
  }
}

function normalizeTask(value: unknown, fallbackCategory: Category): TaskPayload {
  const task = value as Partial<TaskPayload>;
  return {
    title: typeof task.title === "string" ? task.title : "Untitled task",
    completed: task.completed === true,
    category: readCategory(task.category, fallbackCategory),
    tags: Array.isArray(task.tags) ? readTags(task.tags) : [],
    createdAt: typeof task.createdAt === "string" ? task.createdAt : new Date(0).toISOString(),
    updatedAt: typeof task.updatedAt === "string" ? task.updatedAt : new Date(0).toISOString(),
  };
}

function requireTitle(value: unknown): string {
  if (typeof value !== "string") throw new HttpError(400, "title must be a string");
  const title = value.trim();
  if (title.length === 0 || title.length > 120) {
    throw new HttpError(400, "title must contain 1 to 120 characters");
  }
  return title;
}

function readCompleted(value: unknown, fallback: boolean): boolean {
  if (value === undefined) return fallback;
  if (typeof value !== "boolean") throw new HttpError(400, "completed must be a boolean");
  return value;
}

function readCategory(value: unknown, fallback: Category): Category {
  if (value === undefined) return fallback;
  if (typeof value !== "string" || !categories.includes(value as Category)) {
    throw new HttpError(400, `category must be one of: ${categories.join(", ")}`);
  }
  return value as Category;
}

function readTags(value: unknown): string[] {
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw new HttpError(400, "tags must be an array");
  if (value.length > 6) throw new HttpError(400, "tags must contain at most 6 values");
  const tags: string[] = [];
  for (const item of value) {
    if (typeof item !== "string") throw new HttpError(400, "each tag must be a string");
    const tag = item.trim().toLowerCase();
    if (!/^[a-z0-9][a-z0-9-]{0,23}$/.test(tag)) {
      throw new HttpError(400, "tags must use 1 to 24 lowercase letters, numbers, or hyphens");
    }
    if (!tags.includes(tag)) tags.push(tag);
  }
  return tags;
}

function readPort(value: string | undefined, fallback: number): number {
  const parsed = Number(value ?? fallback);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 65535) {
    throw new Error("PORT must be an integer in 1..65535");
  }
  return parsed;
}
