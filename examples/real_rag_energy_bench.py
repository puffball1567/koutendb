#!/usr/bin/env python3
"""Evaluate real QA quality and request energy through KoutenDB and trained models."""

import argparse
import collections
import contextlib
import hashlib
import json
import platform
import random
import re
import statistics
import string
import tempfile
import time
from pathlib import Path

import numpy as np
import torch
from transformers import AutoModel, AutoModelForSeq2SeqLM, AutoTokenizer

from rag_energy_capi import Database
from rag_context import ContextPacker
from rag_routing import PrototypeRouter, retrieve_rings
from transformer_energy_bench import PackageEnergy, SudoPackageEnergy


ARMS = ("global_8", "global_3", "oracle_ring_3", "auto_ring_3", "no_context")
OPTIMIZED_ARMS = ("global_compact_3", "oracle_compact_3", "auto_compact_3")


def normalize(text):
    text = text.lower().translate(str.maketrans("", "", string.punctuation))
    return " ".join(re.sub(r"\b(a|an|the)\b", " ", text).split())


def score_answer(prediction, answers):
    predicted = normalize(prediction).split()
    em, f1 = 0.0, 0.0
    for answer in answers:
        gold = normalize(answer).split()
        em = max(em, float(predicted == gold))
        overlap = sum((collections.Counter(predicted) & collections.Counter(gold)).values())
        value = (2 * overlap / (len(predicted) + len(gold))
                 if predicted or gold else 1.0)
        f1 = max(f1, value)
    return em, f1


def build_corpus(data, tokenizer, chunk_tokens, overlap, seed):
    documents, question_pools = [], []
    rng = random.Random(seed)
    for article_index, article in enumerate(data["data"]):
        ring = f"squad/article-{article_index:03d}"
        pool = []
        for paragraph_index, paragraph in enumerate(article["paragraphs"]):
            paragraph_id = f"{article_index}:{paragraph_index}"
            text = paragraph["context"]
            offsets = tokenizer(text, add_special_tokens=False,
                                return_offsets_mapping=True, verbose=False)["offset_mapping"]
            for start in range(0, len(offsets), chunk_tokens - overlap):
                end = min(start + chunk_tokens, len(offsets))
                left, right = offsets[start][0], offsets[end - 1][1]
                documents.append({"id": f"{paragraph_id}:{start}", "paragraph_id": paragraph_id,
                                  "ring": ring, "title": article["title"],
                                  "text": text[left:right]})
                if end == len(offsets):
                    break
            # One question per paragraph: avoid treating near-duplicate questions
            # about the same passage as independent evaluation units.
            if paragraph["qas"]:
                qa = rng.choice(paragraph["qas"])
                pool.append({"id": qa["id"], "question": qa["question"],
                             "answers": [a["text"] for a in qa["answers"]],
                             "paragraph_id": paragraph_id, "ring": ring})
        rng.shuffle(pool)
        question_pools.append(pool)
    # Round-robin shuffled articles makes the small evaluation topic-diverse.
    rng.shuffle(question_pools)
    questions = []
    while any(question_pools):
        for pool in question_pools:
            if pool:
                questions.append(pool.pop())
    return documents, questions


class Embedder:
    def __init__(self, directory):
        self.tokenizer = AutoTokenizer.from_pretrained(directory, local_files_only=True,
                                                        trust_remote_code=False)
        self.model = AutoModel.from_pretrained(directory, local_files_only=True,
                                               trust_remote_code=False,
                                               use_safetensors=True).eval()

    def encode(self, texts):
        encoded = self.tokenizer(texts, padding=True, truncation=True, max_length=256,
                                 return_tensors="pt")
        hidden = self.model(**encoded).last_hidden_state
        mask = encoded["attention_mask"].unsqueeze(-1)
        pooled = (hidden * mask).sum(1) / mask.sum(1).clamp(min=1)
        return torch.nn.functional.normalize(pooled, p=2, dim=1).numpy()


def select_ring(vector, ring_names, centroids, margin):
    scores = centroids @ vector
    best = np.argsort(scores)[::-1]
    gap = float(scores[best[0]] - scores[best[1]]) if len(best) > 1 else 1.0
    return (ring_names[int(best[0])] if gap >= margin else ""), gap


def pack_prompt(question, hits, tokenizer, max_tokens):
    def render(documents):
        if not documents:
            return f"Answer the question with a short answer.\nQuestion: {question}\nAnswer:"
        context = "\n\n".join(f"{doc['title']}: {doc['text']}" for doc in documents)
        return (f"Answer the question based on the context. Give a short answer.\n"
                f"Context: {context}\nQuestion: {question}\nAnswer:")

    selected = []
    for hit in hits:
        candidate = selected + [hit["document"]]
        if len(tokenizer.encode(render(candidate), verbose=False)) > max_tokens:
            break
        selected = candidate
    prompt = render(selected)
    encoded = tokenizer(prompt, return_tensors="pt", truncation=False, verbose=False)
    if encoded["input_ids"].shape[1] > max_tokens:
        raise ValueError("question/instructions exceed the input token budget")
    return encoded, selected


def run_request(question, arm, db, embedder, generator, tokenizer, rings, centroids, args,
                context_packer=None, prototype_router=None):
    stages = {}
    start = time.perf_counter()
    hits, scanned, ring, gap, fallback = [], 0, "", None, False
    selected_rings, router_vectors = [], 0
    if arm != "no_context":
        vector = embedder.encode([question["question"]])[0]
        stages["embedding_ms"] = 1000 * (time.perf_counter() - start)
        route_start = time.perf_counter()
        budget = 8 if arm == "global_8" else 3
        if arm in ("oracle_ring_3", "oracle_compact_3"):
            # Explicit conditional control. Never presented as inferred routing.
            ring = question["ring"]
        elif arm == "auto_ring_3":
            ring, gap = select_ring(vector, rings, centroids, args.route_margin)
            fallback = not bool(ring)
            router_vectors = len(rings)
        if arm == "auto_compact_3":
            selected_rings, gap = prototype_router.select(vector, args.routing_rings,
                                                          args.prototype_gap)
            router_vectors = len(prototype_router.centers)
            fallback = not bool(selected_rings)
            hits, scanned = retrieve_rings(db, vector, budget, selected_rings)
        else:
            selected_rings = [ring] if ring else []
            hits, scanned = db.retrieve(vector, budget, ring)
        if arm in ("auto_ring_3", "auto_compact_3") and selected_rings and (not hits or hits[0]["score"] < args.min_hit_score):
            hits, extra = db.retrieve(vector, budget)
            scanned += extra
            fallback = True
            ring = ""
            selected_rings = []
        stages["routing_retrieval_ms"] = 1000 * (time.perf_counter() - route_start)
    token_start = time.perf_counter()
    context_hits = context_packer.pack(question["question"], hits) if arm in OPTIMIZED_ARMS else hits
    encoded, documents = pack_prompt(question["question"], context_hits, tokenizer, args.input_tokens)
    stages["prompt_tokenization_ms"] = 1000 * (time.perf_counter() - token_start)
    generate_start = time.perf_counter()
    output = generator.generate(**encoded, max_new_tokens=args.new_tokens,
                                 do_sample=False, num_beams=1, use_cache=True)
    stages["generation_ms"] = 1000 * (time.perf_counter() - generate_start)
    answer = tokenizer.decode(output[0], skip_special_tokens=True)
    return {"prediction": answer, "input_tokens": int(encoded["input_ids"].shape[1]),
            "output_tokens": int(output.shape[1] - 1), "scanned": scanned,
            "returned": len(hits), "packed_documents": len(documents),
            "omitted_documents": len(context_hits) - len(documents),
            "merged_documents": len(hits) - len(context_hits),
            "selected_ring": ring, "route_margin": gap, "fallback": fallback,
            "selected_rings": selected_rings, "router_vectors_scored": router_vectors,
            "source_recalled": any(d["paragraph_id"] == question["paragraph_id"] for d in documents),
            "evidence_text": " ".join(d["text"] for d in documents), "stages": stages}


def bootstrap_comparison(baseline, candidate, margin, seed, iterations=2000):
    names = sorted(baseline)
    rng = np.random.default_rng(seed)
    a = np.array([baseline[name]["f1"] for name in names])
    b = np.array([candidate[name]["f1"] for name in names])
    indices = rng.integers(0, len(names), (iterations, len(names)))
    differences = (b[indices] - a[indices]).mean(axis=1)
    result = {"f1_delta": float((b - a).mean()),
              "f1_delta_95pct_ci": np.quantile(differences, [0.025, 0.975]).tolist(),
              "prespecified_f1_margin": margin,
              "quality_noninferiority_demonstrated": bool(np.quantile(differences, 0.025) >= -margin)}
    if all(baseline[name]["package_j"] is not None and candidate[name]["package_j"] is not None
           for name in names):
        a_j = np.array([baseline[name]["package_j"] for name in names])
        b_j = np.array([candidate[name]["package_j"] for name in names])
        reductions = 100 * (1 - b_j[indices].mean(1) / a_j[indices].mean(1))
        result["energy_reduction_pct"] = float(100 * (1 - b_j.mean() / a_j.mean()))
        result["energy_reduction_pct_95pct_ci"] = np.quantile(reductions, [0.025, 0.975]).tolist()
        result["quality_preserving_energy_savings_demonstrated"] = bool(
            result["quality_noninferiority_demonstrated"] and np.quantile(reductions, 0.025) > 0)
    else:
        result["energy_reduction_pct"] = None
        result["quality_preserving_energy_savings_demonstrated"] = False
    return result


def aggregate(rows):
    per_arm, summaries = {}, {}
    for arm in (*ARMS, *OPTIMIZED_ARMS):
        questions = collections.defaultdict(list)
        for row in rows:
            if row["arm"] == arm:
                questions[row["query_id"]].append(row)
        if not questions:
            continue
        per_arm[arm] = {}
        for qid, samples in questions.items():
            per_arm[arm][qid] = {key: (None if samples[0][key] is None else
                                       statistics.mean(row[key] for row in samples))
                                 for key in ("f1", "em", "package_j", "wall_ms", "cpu_ms", "input_tokens",
                                             "output_tokens", "scanned", "source_recalled", "evidence_recalled",
                                             "fallback", "omitted_documents")}
        values = list(per_arm[arm].values())
        summaries[arm] = {f"mean_{key}": (None if values[0][key] is None else
                                          statistics.mean(value[key] for value in values))
                          for key in values[0]}
        summaries[arm]["prediction_changes_across_repeats"] = sum(
            len({row["prediction"] for row in samples}) > 1 for samples in questions.values())
        all_rows = [row for samples in questions.values() for row in samples]
        summaries[arm]["aggregate_package_w"] = (
            None if any(row["package_j"] is None for row in all_rows) else
            1000 * sum(row["package_j"] for row in all_rows) / sum(row["wall_ms"] for row in all_rows))
    return per_arm, summaries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=Path(".tmp/rag-energy"))
    parser.add_argument("--library", type=Path, default=Path("lib/libkoutendb.so"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--queries", type=int, default=40)
    parser.add_argument("--query-offset", type=int, default=0,
                        help="skip previously inspected questions for a held-out evaluation")
    parser.add_argument("--arms", default=",".join(ARMS))
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--chunk-tokens", type=int, default=96)
    parser.add_argument("--chunk-overlap", type=int, default=16)
    parser.add_argument("--input-tokens", type=int, default=1024)
    parser.add_argument("--new-tokens", type=int, default=32)
    parser.add_argument("--route-margin", type=float, default=0.03)
    parser.add_argument("--min-hit-score", type=float, default=0.25)
    parser.add_argument("--quality-margin", type=float, default=0.05)
    parser.add_argument("--seed", type=int, default=1567)
    parser.add_argument("--context-sentences", type=int, default=2)
    parser.add_argument("--routing-prototypes", type=int, default=8)
    parser.add_argument("--routing-rings", type=int, default=4)
    parser.add_argument("--prototype-gap", type=float, default=.015)
    parser.add_argument("--sudo-energy", action="store_true")
    parser.add_argument("--require-energy", action="store_true")
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    arms = args.arms.split(",")
    if not arms or len(set(arms)) != len(arms) or any(arm not in (*ARMS, *OPTIMIZED_ARMS) for arm in arms):
        parser.error("arms must be a comma-separated list of distinct supported comparison conditions")
    if min(args.queries, args.repeats, args.threads, args.chunk_tokens, args.input_tokens,
           args.new_tokens) < 1 or not 0 <= args.chunk_overlap < args.chunk_tokens:
        parser.error("counts must be positive and chunk overlap must be smaller than chunk size")
    if not 0 <= args.quality_margin <= 1 or not 0 <= args.route_margin <= 2:
        parser.error("invalid quality or routing margin")
    if args.query_offset < 0 or min(args.context_sentences, args.routing_prototypes, args.routing_rings) < 1 or not 0 <= args.prototype_gap <= 2:
        parser.error("invalid held-out offset or context/routing settings")
    torch.set_num_threads(args.threads)
    torch.set_num_interop_threads(1)
    torch.manual_seed(args.seed)
    work = args.work.resolve()
    sources = json.loads((work / "sources.json").read_text())
    data_bytes = (work / sources["dataset"]["file"]).read_bytes()
    if hashlib.sha256(data_bytes).hexdigest() != sources["dataset"]["sha256"]:
        raise ValueError("SQuAD dataset SHA-256 does not match the source manifest")
    tokenizer = AutoTokenizer.from_pretrained(work / "models/generator", local_files_only=True,
                                               trust_remote_code=False)
    signature = {"sources": sources, "chunk_tokens": args.chunk_tokens,
                 "chunk_overlap": args.chunk_overlap, "seed": args.seed}
    cache_manifest = work / "corpus-manifest.json"
    valid_cache = (cache_manifest.exists() and json.loads(cache_manifest.read_text()) == signature
                   and all((work / file).exists() for file in ("documents.json", "questions.json", "vectors.npy")))
    embedder = Embedder(work / "models/embedding")
    with torch.inference_mode():
        if valid_cache:
            documents = json.loads((work / "documents.json").read_text())
            questions = json.loads((work / "questions.json").read_text())
            vectors = np.load(work / "vectors.npy", allow_pickle=False)
        else:
            documents, questions = build_corpus(json.loads(data_bytes), tokenizer, args.chunk_tokens,
                                                args.chunk_overlap, args.seed)
            batches = []
            for start in range(0, len(documents), 32):
                batch = documents[start:start + 32]
                batches.append(embedder.encode([doc["title"] + ": " + doc["text"] for doc in batch]))
                if start % 320 == 0:
                    print(f"Embedding documents {start}/{len(documents)}", flush=True)
            vectors = np.concatenate(batches)
            (work / "documents.json").write_text(json.dumps(documents))
            (work / "questions.json").write_text(json.dumps(questions))
            np.save(work / "vectors.npy", vectors, allow_pickle=False)
            cache_manifest.write_text(json.dumps(signature, indent=2) + "\n")
    if vectors.shape != (len(documents), 384):
        raise ValueError("unexpected embedding cache dimensions")
    print(f"Prepared {len(documents)} chunks, {len(questions)} independent question candidates", flush=True)
    if args.prepare_only:
        return
    if args.query_offset + args.queries > len(questions):
        parser.error("requested more independent paragraphs than are available")
    questions = questions[args.query_offset:args.query_offset + args.queries]
    ring_names = sorted({doc["ring"] for doc in documents})
    centroids = np.array([vectors[[i for i, doc in enumerate(documents) if doc["ring"] == ring]].mean(0)
                          for ring in ring_names])
    centroids /= np.maximum(np.linalg.norm(centroids, axis=1, keepdims=True), 1e-9)
    policy_start = time.perf_counter()
    context_packer = ContextPacker(args.context_sentences) if any(arm in OPTIMIZED_ARMS for arm in arms) else None
    prototype_router = PrototypeRouter(documents, vectors, args.routing_prototypes) if "auto_compact_3" in arms else None
    policy_preparation_ms = 1000 * (time.perf_counter() - policy_start)
    generator = AutoModelForSeq2SeqLM.from_pretrained(
        work / "models/generator", local_files_only=True, trust_remote_code=False,
        use_safetensors=True).eval()
    output = args.output or work / "results.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    rows, rng = [], random.Random(args.seed)
    with tempfile.TemporaryDirectory(prefix="koutendb-real-rag-") as data_dir, contextlib.ExitStack() as stack:
        db = Database(args.library, Path(data_dir))
        stack.callback(db.close)
        for doc, vector in zip(documents, vectors):
            db.put(doc, vector)
        print("Database loaded; warming each comparison condition", flush=True)
        with torch.inference_mode():
            for arm in arms:
                run_request(questions[0], arm, db, embedder, generator, tokenizer,
                            ring_names, centroids, args, context_packer, prototype_router)
            energy = SudoPackageEnergy() if args.sudo_energy else PackageEnergy()
            stack.callback(energy.close)
            if args.require_energy and not energy.status["available"]:
                raise RuntimeError(f"Energy measurement required: {energy.status['reason']}")
            print(f"Energy: {energy.status}", flush=True)
            with output.with_suffix(".requests.jsonl").open("w") as journal:
                for repeat in range(args.repeats):
                    query_order = list(questions)
                    rng.shuffle(query_order)
                    for index, question in enumerate(query_order):
                        arm_order = list(arms)
                        rng.shuffle(arm_order)
                        for arm in arm_order:
                            before = energy.read()
                            wall, cpu = time.perf_counter(), time.process_time()
                            row = run_request(question, arm, db, embedder, generator, tokenizer,
                                              ring_names, centroids, args, context_packer, prototype_router)
                            wall_ms, cpu_ms = 1000 * (time.perf_counter() - wall), 1000 * (time.process_time() - cpu)
                            joules = energy.joules(before, energy.read())
                            em, f1 = score_answer(row["prediction"], question["answers"])
                            evidence = normalize(row.pop("evidence_text"))
                            row.update({"query_id": question["id"], "repeat": repeat, "arm": arm,
                                        "wall_ms": wall_ms, "cpu_ms": cpu_ms, "package_j": joules,
                                        "package_w": None if joules is None else 1000 * joules / wall_ms,
                                        "em": em, "f1": f1,
                                        "evidence_recalled": any(normalize(a) and
                                                                 f" {normalize(a)} " in f" {evidence} "
                                                                 for a in question["answers"]),
                                        "route_correct": question["ring"] in row["selected_rings"]})
                            rows.append(row)
                            journal.write(json.dumps(row) + "\n")
                            journal.flush()
                        print(f"repeat {repeat + 1}/{args.repeats}: query {index + 1}/{len(questions)}", flush=True)
    per_arm, summaries = aggregate(rows)
    comparisons = {f"{arm}_vs_{base}": bootstrap_comparison(per_arm[base], per_arm[arm],
                                                           args.quality_margin, args.seed)
                   for base in ("global_8", "global_3", "global_compact_3") if base in per_arm
                   for arm in ("oracle_ring_3", "auto_ring_3", *OPTIMIZED_ARMS) if arm in per_arm and arm != base}
    report = {"schema_version": 1, "scope": "warm_question_to_decoded_answer",
              "sources": sources, "model_parameters": sum(p.numel() for p in generator.parameters()),
              "environment": {"python": platform.python_version(), "torch": torch.__version__,
                              "machine": platform.machine(), "threads": args.threads},
              "configuration": {key: value for key, value in vars(args).items()
                                if key not in ("work", "library", "output")},
              "corpus_chunks": len(documents), "rings": len(ring_names),
              "library_sha256": hashlib.sha256(args.library.read_bytes()).hexdigest(),
              "policy_preparation_ms": policy_preparation_ms,
              "implementation_sha256": {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                                         for name in ("real_rag_energy_bench.py", "rag_context.py", "rag_routing.py")},
              "query_ids": [question["id"] for question in questions],
              "energy": energy.status, "summaries": summaries, "comparisons": comparisons,
              "limitations": ["Public SQuAD data may overlap model training; not an unseen-data claim.",
                              "oracle_ring_3 uses the labelled source article as supplied scope, not learned routing.",
                              "auto_ring_3 uses only document centroids and the question; thresholds are fixed before evaluation.",
                              "Compact context is a heuristic; compare against global_compact_3 to separate context savings from ring savings.",
                              "auto_compact_3 uses document-only prototypes and may search multiple rings or fall back globally.",
                              "Single-source English QA; not a cross-ring/multihop or production workload.",
                              "EM and token F1 do not measure every aspect of answer quality.",
                              "Paired bootstrap resamples questions, not repeated measurements; topic correlations remain.",
                              "Warm CPU package energy includes background activity; not whole-machine energy.",
                              "Offline corpus embedding, import, warmup and model loading are excluded."]}
    output.write_text(json.dumps(report, indent=2) + "\n")
    print("arm               EM      F1   source_recall   input_tokens    ms/request    J/request")
    for arm, summary in summaries.items():
        j = summary["mean_package_j"]
        print(f"{arm:16} {summary['mean_em']:6.3f} {summary['mean_f1']:7.3f}"
              f" {summary['mean_source_recalled']:14.3f} {summary['mean_input_tokens']:14.1f}"
              f" {summary['mean_wall_ms']:13.2f} {'unavailable' if j is None else f'{j:.6f}':>12}")
    print(f"Report: {output}", flush=True)


if __name__ == "__main__":
    main()
