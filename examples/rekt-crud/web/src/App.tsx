import { FormEvent, useCallback, useEffect, useMemo, useState } from "react";
import {
  Check,
  Circle,
  Database,
  Network,
  Pencil,
  Plus,
  RefreshCw,
  Trash2,
  X,
} from "lucide-react";

interface Task {
  id: string;
  title: string;
  completed: boolean;
  category: string;
  tags: string[];
  createdAt: string;
  updatedAt: string;
}

interface TaskPage {
  items: Task[];
  count: number;
}

interface DemoMeta {
  ring: string;
  categories: string[];
}

interface RelatedTask extends Task {
  sharedTags: string[];
  score: number;
}

interface RelatedPage {
  task: Task;
  scope: {
    ring: string;
    candidates: number;
    categoriesScanned: number;
  };
  items: RelatedTask[];
}

const stackLabel = import.meta.env.VITE_STACK_LABEL ?? "REKT";
const stackDetail = import.meta.env.VITE_STACK_DETAIL ?? "React + Express + KoutenDB + TypeScript";
const fallbackCategories = ["general", "planning", "engineering", "research", "operations"];

export function App() {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [categories, setCategories] = useState(fallbackCategories);
  const [ring, setRing] = useState("demo/tasks");
  const [title, setTitle] = useState("");
  const [category, setCategory] = useState("general");
  const [tags, setTags] = useState("");
  const [categoryFilter, setCategoryFilter] = useState("all");
  const [editing, setEditing] = useState<Task | null>(null);
  const [related, setRelated] = useState<RelatedPage | null>(null);
  const [relatedLoading, setRelatedLoading] = useState("");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  const loadTasks = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const [page, meta] = await Promise.all([
        api<TaskPage>("/api/tasks"),
        api<DemoMeta>("/api/meta"),
      ]);
      setTasks(page.items);
      setCategories(meta.categories);
      setRing(meta.ring);
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadTasks();
  }, [loadTasks]);

  useEffect(() => {
    document.title = `KoutenDB ${stackLabel} Tasks`;
  }, []);

  const visibleTasks = useMemo(
    () => categoryFilter === "all"
      ? tasks
      : tasks.filter((task) => task.category === categoryFilter),
    [tasks, categoryFilter],
  );

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!title.trim()) return;
    setSaving(true);
    setError("");
    try {
      const body = JSON.stringify({
        title,
        category,
        tags: parseTags(tags),
        completed: editing?.completed ?? false,
      });
      if (editing) {
        await api(`/api/tasks/${encodeURIComponent(editing.id)}`, { method: "PUT", body });
      } else {
        await api("/api/tasks", { method: "POST", body });
      }
      resetForm();
      setRelated(null);
      await loadTasks();
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      setSaving(false);
    }
  }

  async function toggle(task: Task) {
    await mutate(task, { ...task, completed: !task.completed });
  }

  async function remove(task: Task) {
    setError("");
    try {
      await api(`/api/tasks/${encodeURIComponent(task.id)}`, { method: "DELETE" });
      if (editing?.id === task.id) resetForm();
      if (related?.task.id === task.id) setRelated(null);
      await loadTasks();
    } catch (reason) {
      setError(errorMessage(reason));
    }
  }

  async function mutate(task: Task, body: Pick<Task, "title" | "completed" | "category" | "tags">) {
    setError("");
    try {
      await api(`/api/tasks/${encodeURIComponent(task.id)}`, {
        method: "PUT",
        body: JSON.stringify(body),
      });
      setRelated(null);
      await loadTasks();
    } catch (reason) {
      setError(errorMessage(reason));
    }
  }

  async function showRelated(task: Task) {
    if (related?.task.id === task.id) {
      setRelated(null);
      return;
    }
    setRelatedLoading(task.id);
    setError("");
    try {
      setRelated(await api<RelatedPage>(`/api/tasks/${encodeURIComponent(task.id)}/related`));
    } catch (reason) {
      setError(errorMessage(reason));
    } finally {
      setRelatedLoading("");
    }
  }

  function edit(task: Task) {
    setEditing(task);
    setTitle(task.title);
    setCategory(task.category);
    setTags(task.tags.join(", "));
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  function resetForm() {
    setEditing(null);
    setTitle("");
    setCategory("general");
    setTags("");
  }

  const openCount = visibleTasks.filter((task) => !task.completed).length;

  return (
    <main className="app-shell">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark"><Database size={20} /></span>
          <div>
            <strong>KoutenDB Tasks</strong>
            <span>{stackLabel} stack</span>
          </div>
        </div>
        <div className="connection"><span /> {ring}</div>
      </header>

      <section className="workspace">
        <div className="section-heading">
          <div>
            <p className="eyebrow">{stackDetail}</p>
            <h1>Task workspace</h1>
          </div>
          <button className="icon-button" onClick={() => void loadTasks()} title="Refresh tasks" aria-label="Refresh tasks">
            <RefreshCw size={18} className={loading ? "spin" : ""} />
          </button>
        </div>

        <form className="task-form" onSubmit={submit}>
          <div className="form-grid">
            <label className="field title-field" htmlFor="task-title">
              <span>{editing ? "Edit task" : "New task"}</span>
              <input
                id="task-title"
                value={title}
                onChange={(event) => setTitle(event.target.value)}
                maxLength={120}
                placeholder="What needs to be done?"
                autoComplete="off"
              />
            </label>
            <label className="field" htmlFor="task-category">
              <span>Category</span>
              <select id="task-category" value={category} onChange={(event) => setCategory(event.target.value)}>
                {categories.map((value) => <option value={value} key={value}>{categoryLabel(value)}</option>)}
              </select>
            </label>
            <label className="field" htmlFor="task-tags">
              <span>Tags</span>
              <input
                id="task-tags"
                value={tags}
                onChange={(event) => setTags(event.target.value)}
                placeholder="api, docker, rag"
                autoComplete="off"
              />
            </label>
          </div>
          <div className="form-actions">
            {editing && (
              <button type="button" className="secondary-button" onClick={resetForm}>
                <X size={18} /> Cancel
              </button>
            )}
            <button className="primary-button" disabled={saving || !title.trim()}>
              {editing ? <Check size={18} /> : <Plus size={18} />}
              {editing ? "Save task" : "Add task"}
            </button>
          </div>
        </form>

        {error && <div className="error-banner" role="alert">{error}</div>}

        <div className="list-heading">
          <h2>Tasks</h2>
          <span>{openCount} open / {visibleTasks.length} shown</span>
        </div>

        <div className="category-tabs" role="group" aria-label="Filter tasks by category">
          {["all", ...categories].map((value) => (
            <button
              className={categoryFilter === value ? "active" : ""}
              type="button"
              onClick={() => setCategoryFilter(value)}
              key={value}
            >
              {value === "all" ? "All" : categoryLabel(value)}
              <span>{value === "all" ? tasks.length : tasks.filter((task) => task.category === value).length}</span>
            </button>
          ))}
        </div>

        <div className="task-list" aria-live="polite">
          {loading && tasks.length === 0 ? (
            <div className="empty-state">Loading tasks...</div>
          ) : visibleTasks.length === 0 ? (
            <div className="empty-state">No tasks in this category ring.</div>
          ) : visibleTasks.map((task) => (
            <article className={`task-item ${task.completed ? "completed" : ""}`} key={task.id}>
              <button className="status-button" onClick={() => void toggle(task)} title="Toggle completion" aria-label="Toggle completion">
                {task.completed ? <Check size={18} /> : <Circle size={18} />}
              </button>
              <div className="task-copy">
                <div className="task-title-row">
                  <strong>{task.title}</strong>
                  <span className="category-badge">{categoryLabel(task.category)}</span>
                </div>
                <div className="tag-row">
                  {task.tags.map((tag) => <span className="tag" key={tag}>#{tag}</span>)}
                  {task.tags.length === 0 && <span className="no-tags">No tags</span>}
                </div>
                <span className="task-meta">{shortId(task.id)} · updated {formatTime(task.updatedAt)}</span>
              </div>
              <div className="task-actions">
                <button
                  className={`related-button ${related?.task.id === task.id ? "active" : ""}`}
                  onClick={() => void showRelated(task)}
                  title="Find related tasks"
                  aria-label="Find related tasks"
                >
                  <Network size={17} className={relatedLoading === task.id ? "spin" : ""} />
                  <span>Related</span>
                </button>
                <button className="icon-button" onClick={() => edit(task)} title="Edit task" aria-label="Edit task"><Pencil size={17} /></button>
                <button className="icon-button danger" onClick={() => void remove(task)} title="Delete task" aria-label="Delete task"><Trash2 size={17} /></button>
              </div>
            </article>
          ))}
        </div>

        {related && (
          <section className="related-panel">
            <div className="related-heading">
              <div>
                <p className="eyebrow">Related to {related.task.title}</p>
                <h2>Category-local context</h2>
              </div>
              <button className="icon-button" onClick={() => setRelated(null)} title="Close related tasks" aria-label="Close related tasks">
                <X size={18} />
              </button>
            </div>
            <div className="scope-line">
              <code>{related.scope.ring}</code>
              <span>{related.scope.candidates} candidates · {related.scope.categoriesScanned} ring read</span>
            </div>
            <div className="related-list">
              {related.items.length === 0 ? (
                <div className="empty-state">No other tasks in this category ring.</div>
              ) : related.items.map((task) => (
                <article className="related-item" key={task.id}>
                  <div>
                    <strong>{task.title}</strong>
                    <span>{task.sharedTags.length > 0 ? `${task.sharedTags.length} shared tag${task.sharedTags.length === 1 ? "" : "s"}` : "Same category"}</span>
                  </div>
                  <div className="tag-row">
                    {task.sharedTags.map((tag) => <span className="tag shared" key={tag}>#{tag}</span>)}
                  </div>
                </article>
              ))}
            </div>
          </section>
        )}
      </section>
    </main>
  );
}

async function api<T = unknown>(path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(path, {
    ...init,
    headers: { "Content-Type": "application/json", ...init.headers },
  });
  if (!response.ok) {
    const body = await response.json().catch(() => ({ error: response.statusText })) as { error?: string };
    throw new Error(body.error ?? `request failed (${response.status})`);
  }
  if (response.status === 204) return undefined as T;
  return response.json() as Promise<T>;
}

function parseTags(value: string): string[] {
  return [...new Set(value.split(",").map((tag) => tag.trim().toLowerCase()).filter(Boolean))];
}

function categoryLabel(value: string): string {
  return value.charAt(0).toUpperCase() + value.slice(1);
}

function errorMessage(reason: unknown): string {
  return reason instanceof Error ? reason.message : "Unexpected error";
}

function shortId(id: string): string {
  const parts = id.split("_");
  return parts.length === 4 ? `ID ${parts[2]}` : id;
}

function formatTime(value: string): string {
  return new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" }).format(new Date(value));
}
