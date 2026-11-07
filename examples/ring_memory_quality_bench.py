#!/usr/bin/env python3
"""Train matched dense/ring models; hold out questions and unordered fact pairs."""

import argparse
import copy
import hashlib
import json
import platform
import random
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import torch
from torch import nn

from ring_memory_data import encode, make_task
from ring_memory_experiment import accuracy, macro_accuracy, parser_accuracy, role_targets
from ring_memory_model import TaskModel, TensorMemoryStore


ROOT = Path(__file__).resolve().parents[1]
CONFIGURATIONS = {"dense": (64, 32), "ring_coarse": (16, 128), "ring_fine": (64, 32)}
PARSER_PREFIXES = ("embedding.", "position.", "stem.", "entity_head.", "attribute_head.",
                   "operation_head.", "semantic_codes")


def disk_usage(work):
    size = sum(path.stat().st_size for path in work.rglob("*") if path.is_file())
    if size > 112 * 1024**2:
        raise RuntimeError("accuracy probe approached its 128 MiB disk budget")
    return size


def make_models(task, seed):
    models = {}
    for name, (rings, slots) in CONFIGURATIONS.items():
        torch.manual_seed(seed)
        models[name] = TaskModel(len(task["vocabulary"]), task["values"] + 2, entities=task["parser_entities"],
                                rings=rings, slots=slots, kind="dense" if name == "dense" else "ring")
    common = {key: value for key, value in models["dense"].state_dict().items()
              if not key.startswith("knowledge.")}
    for model in models.values():
        model.load_state_dict(common, strict=False)
    return models


def train_seed(args, directory):
    task = make_task(args.seed, entities=args.entities, pairs=args.training_pairs, evaluation_pairs=args.evaluation_pairs)
    models = make_models(task, args.seed)
    parser_model = models["dense"]
    parser_parameters = [p for name, p in parser_model.named_parameters()
                         if name.startswith(PARSER_PREFIXES) and p.requires_grad]
    optimizer = torch.optim.AdamW(parser_parameters, lr=.003, weight_decay=.001)
    best_parser, parser_state, parser_history = -1., None, []
    rng = random.Random(args.seed)
    started = time.perf_counter()
    for step in range(1, args.parser_steps + 1):
        parser_model.train()
        rows = rng.choices(task["parser_training"], k=args.batch_size)
        ids, _ = encode(rows, task["vocabulary"])
        targets, outputs = role_targets(rows), parser_model.parser_logits(ids)
        loss = sum(nn.functional.cross_entropy(p.flatten(0, -2), y.flatten()) for p, y in zip(outputs[:2], targets[:2]))
        loss = loss + nn.functional.cross_entropy(outputs[2], targets[2])
        optimizer.zero_grad(set_to_none=True)
        loss.backward()
        nn.utils.clip_grad_norm_(parser_parameters, 1.)
        optimizer.step()
        if step % args.validate_every == 0 or step == args.parser_steps:
            scores = parser_accuracy(parser_model, task["validation"], task["vocabulary"])
            parser_history.append({"step": step, "validation": scores})
            if statistics.mean(scores.values()) > best_parser:
                best_parser = statistics.mean(scores.values())
                parser_state = {key: value.clone() for key, value in parser_model.state_dict().items()
                                if key.startswith(PARSER_PREFIXES)}
            print(json.dumps({"seed": args.seed, "parser": parser_history[-1]}), flush=True)
    for model in models.values():
        model.load_state_dict(parser_state, strict=False)
        model.freeze_parser()
    parser_seconds = time.perf_counter() - started
    optimizers = {name: torch.optim.AdamW((p for p in model.parameters() if p.requires_grad), lr=.003, weight_decay=.001)
                  for name, model in models.items()}
    best = {name: {"score": -1.} for name in models}
    rng = random.Random(args.seed + 1)
    history = []
    started = time.perf_counter()
    for step in range(1, args.steps + 1):
        rows = rng.choices(task["train_single"], k=args.batch_size // 2) + rng.choices(
            task["train_composition"], k=args.batch_size - args.batch_size // 2)
        rng.shuffle(rows)
        ids, labels = encode(rows, task["vocabulary"])
        es, ats, _ = role_targets(rows)
        fact_targets = torch.tensor([[task["world"][int(e)][int(a)] for e, a in zip(entity, attribute)]
                                     for entity, attribute in zip(es, ats)])
        for name, model in models.items():
            model.train()
            if name != "dense":
                model.knowledge.soft_training = step <= args.soft_steps
            optimizer = optimizers[name]
            optimizer.zero_grad(set_to_none=True)
            logits, facts = model(ids, return_facts=True)
            loss = nn.functional.cross_entropy(logits, labels) + .5 * nn.functional.cross_entropy(
                facts.flatten(0, 1), fact_targets.flatten())
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 1.)
            optimizer.step()
        if step % args.validate_every == 0 or step == args.steps:
            scores = {name: accuracy(model, task["validation"], task["vocabulary"]) for name, model in models.items()}
            for name, model in models.items():
                score = macro_accuracy(scores[name])
                if step > args.soft_steps and score > best[name]["score"]:
                    best[name] = {"score": score, "step": step, "state": copy.deepcopy(model.state_dict())}
            history.append({"step": step, "validation": scores})
            print(json.dumps({"seed": args.seed, "knowledge": history[-1]}), flush=True)
    checkpoint = {"schema_version": 1, "seed": args.seed, "entities": args.entities, "task": task,
                  "models": {name: entry["state"] for name, entry in best.items()},
                  "training": {"parser_steps": args.parser_steps, "steps": args.steps, "soft_steps": args.soft_steps,
                               "batch_size": args.batch_size, "parser_history": parser_history, "history": history,
                               "selected_steps": {name: entry["step"] for name, entry in best.items()},
                               "parser_seconds": parser_seconds, "knowledge_seconds": time.perf_counter() - started}}
    torch.save(checkpoint, directory / "checkpoint.pt")
    disk_usage(args.work)
    return {"seed": args.seed, "training": checkpoint["training"]}


def detailed_predictions(model, task, backend, batch_size=64):
    model.eval()
    if model.kind == "ring":
        model.knowledge.backend = backend
    rows = []
    with torch.inference_mode():
        for start in range(0, len(task["test"]), batch_size):
            examples = task["test"][start:start + batch_size]
            ids, labels = encode(examples, task["vocabulary"])
            expected_roles = role_targets(examples)
            actual_roles = model.parser_logits(ids)
            parser_ok = (actual_roles[0].argmax(-1).eq(expected_roles[0]).all(-1) &
                         actual_roles[1].argmax(-1).eq(expected_roles[1]).all(-1) &
                         actual_roles[2].argmax(-1).eq(expected_roles[2]))
            logits, fact_logits = model(ids, return_facts=True)
            predictions = logits.argmax(-1)
            decoded = fact_logits.argmax(-1)
            for i, example in enumerate(examples):
                fact_values = [task["world"][e][a] for e, a in (example["facts"][0], example["facts"][-1])]
                rows.append({"index": start + i, "kind": example["kind"], "label": int(labels[i]),
                             "prediction": int(predictions[i]), "correct": bool(predictions[i] == labels[i]),
                             "parser_correct": bool(parser_ok[i]),
                             "both_facts_decoded_correctly": decoded[i].tolist() == fact_values})
    return rows


def summarize(rows):
    result = {}
    for kind in ("single", "composition"):
        group = [row for row in rows if row["kind"] == kind]
        parsed = [row for row in group if row["parser_correct"]]
        decoded = [row for row in group if row["both_facts_decoded_correctly"]]
        result[kind] = {"correct": sum(row["correct"] for row in group), "total": len(group),
                        "accuracy": statistics.mean(row["correct"] for row in group),
                        "parser_correct_questions": len(parsed),
                        "accuracy_when_parser_correct": statistics.mean(row["correct"] for row in parsed) if parsed else None,
                        "both_facts_decoded_accuracy": statistics.mean(row["both_facts_decoded_correctly"] for row in group),
                        "final_errors_with_both_facts_decoded_correctly": sum(not row["correct"] for row in decoded)}
    return result


def evaluate_seed(args, directory):
    checkpoint = torch.load(directory / "checkpoint.pt", weights_only=True)
    task, models = checkpoint["task"], make_models(checkpoint["task"], checkpoint["seed"])
    results, predictions, parity, diagnostics = {}, {}, {}, {}
    peak_bytes = disk_usage(args.work)
    for name, model in models.items():
        model.load_state_dict(checkpoint["models"][name])
        model.freeze_parser()
        model.eval()
        reference = detailed_predictions(model, task, "tensor_sparse", batch_size=1)
        predictions[name] = reference
        results[name] = summarize(reference)
        if name == "dense":
            continue
        with tempfile.TemporaryDirectory(prefix="db-", dir=directory) as temporary:
            store = TensorMemoryStore(args.library, Path(temporary), model.knowledge)
            try:
                peak_bytes = max(peak_bytes, disk_usage(args.work))
                model.knowledge.store = store
                actual = detailed_predictions(model, task, "koutendb", batch_size=1)
                mismatches = sum(a["prediction"] != b["prediction"] for a, b in zip(actual, reference))
                parity[name] = {"prediction_mismatches": mismatches, "questions": len(actual)}
                results[name + "_db"] = summarize(actual)
            finally:
                store.close()
                model.knowledge.store = None
        Path(str(temporary) + ".kouten-dir.lock").unlink(missing_ok=True)
        # These are interventions on the trained model, not separately trained baselines.
        diagnostics[name] = {"zero_read": summarize(detailed_predictions(model, task, "ablated"))}
        # Deliberately misalign routing representatives and their stored rings.
        # Restore the actual weights before any other evaluation or checkpoint use.
        original_keys = model.knowledge.ring_keys.detach().clone()
        try:
            with torch.no_grad():
                model.knowledge.ring_keys.copy_(original_keys.roll(1, 0))
            diagnostics[name]["shifted_ring_routes"] = summarize(detailed_predictions(model, task, "tensor_sparse"))
        finally:
            with torch.no_grad():
                model.knowledge.ring_keys.copy_(original_keys)
            model.eval()
    learned = {row["text"] for row in task["train_single"] + task["train_composition"]}
    parsed = {row["text"] for row in task["parser_training"]}
    test_texts = {row["text"] for row in task["test"]}
    report = {"seed": checkpoint["seed"], "facts": task["entities"] * 3,
              "test_text_overlap_with_knowledge_training": len(test_texts & learned),
              "test_text_overlap_with_parser_training": len(test_texts & parsed),
              "training": checkpoint["training"], "quality": results, "diagnostics": diagnostics,
              "predictions": predictions, "db_parity": parity,
              "peak_file_bytes_observed": peak_bytes,
              "knowledge_parameters": {name: sum(p.numel() for p in m.knowledge.parameters()) for name, m in models.items()}}
    (directory / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def orchestrate(args):
    plan = {"seeds": args.seeds, "entities": args.entities, "facts": args.entities * 3,
            "training_pairs": args.training_pairs, "evaluation_pairs_per_split": args.evaluation_pairs,
            "parser_steps": args.parser_steps, "knowledge_steps": args.steps, "soft_steps": args.soft_steps,
            "batch_size": args.batch_size, "configurations": CONFIGURATIONS,
            "disk_budget_bytes": 128 * 1024**2,
            "exploratory_tolerance": .02,
            "selection": "validation only; train all seeds before opening any held-out test results"}
    (args.work / "plan.json").write_text(json.dumps(plan, indent=2) + "\n")

    def worker(seed, phase):
        command = [sys.executable, str(Path(__file__).resolve()), "--work", str(args.work), "--library", str(args.library),
                   "--worker", phase, "--seed", str(seed), "--entities", str(args.entities),
                   "--training-pairs", str(args.training_pairs), "--evaluation-pairs", str(args.evaluation_pairs),
                   "--parser-steps", str(args.parser_steps), "--steps", str(args.steps), "--soft-steps", str(args.soft_steps),
                   "--batch-size", str(args.batch_size), "--validate-every", str(args.validate_every), "--threads", str(args.threads)]
        subprocess.run(command, check=True, timeout=1800)

    peak_bytes = 0
    for seed in args.seeds:
        worker(seed, "train")
        peak_bytes = max(peak_bytes, disk_usage(args.work))
    reports = []
    for seed in args.seeds:
        worker(seed, "evaluate")
        directory = args.work / f"seed-{seed}"
        reports.append(json.loads((directory / "results.json").read_text()))
        peak_bytes = max(peak_bytes, reports[-1]["peak_file_bytes_observed"], disk_usage(args.work))
        if seed != args.seeds[0]:
            (directory / "checkpoint.pt").unlink()
    aggregate = {}
    for name in CONFIGURATIONS:
        aggregate[name] = {}
        for kind in ("single", "composition"):
            quality_name = name if name == "dense" else name + "_db"
            values = [r["quality"][quality_name][kind]["accuracy"] for r in reports]
            differences = [v - r["quality"]["dense"][kind]["accuracy"] for v, r in zip(values, reports)]
            aggregate[name][kind] = {"mean_accuracy": statistics.mean(values), "seed_accuracies": values,
                                      "differences_vs_dense": differences,
                                      "within_two_percentage_points_every_seed": min(differences) >= -.02}
    result = {"scope": "trained_synthetic_relational_answer_quality", "plan": plan, "aggregate": aggregate,
              "peak_file_bytes_observed": peak_bytes,
              "seeds": reports, "runtime": {"torch": torch.__version__, "python": platform.python_version(), "threads": args.threads},
              "implementation_sha256": {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                                        for name in ("ring_memory_quality_bench.py", "ring_memory_model.py", "ring_memory_data.py")},
              "limitations": ["Synthetic recall and two-fact comparison, not unrestricted natural-language generation.",
                              "The common role parser sees all grammar templates on alias entities, without their fact values.",
                              "Facts are all learned; test holds out question strings and unordered comparison pairs, not new facts.",
                              "Knowledge capacity is approximately 0.65 MiB; the separate 10/40 MiB speed results do not imply equal quality here.",
                              "Two-point tolerance is an exploratory check, not a statistical noninferiority claim."]}
    (args.work / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(aggregate, indent=2), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=ROOT / ".tmp/ring-memory-quality")
    parser.add_argument("--library", type=Path, default=ROOT / "lib/libkoutendb.so")
    parser.add_argument("--seeds", nargs="+", type=int, default=[731, 732, 733])
    parser.add_argument("--entities", type=int, default=128)
    parser.add_argument("--training-pairs", type=int, default=4096)
    parser.add_argument("--evaluation-pairs", type=int, default=512)
    parser.add_argument("--parser-steps", type=int, default=3000)
    parser.add_argument("--steps", type=int, default=2000)
    parser.add_argument("--soft-steps", type=int, default=250)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--validate-every", type=int, default=200)
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--worker", choices=("train", "evaluate"), help=argparse.SUPPRESS)
    parser.add_argument("--seed", type=int, default=731, help=argparse.SUPPRESS)
    args = parser.parse_args()
    args.work, args.library = args.work.resolve(), args.library.resolve()
    if not args.work.is_relative_to(ROOT / ".tmp"):
        parser.error("keep experiment data inside this project's .tmp directory")
    if (args.entities < 128 or min(args.training_pairs, args.evaluation_pairs, args.parser_steps,
            args.steps, args.batch_size, args.validate_every, args.threads) < 1 or not 0 <= args.soft_steps < args.steps):
        parser.error("need >=128 entities, positive counts and warmup below total steps")
    if (args.entities > 256 or args.steps > 10000 or args.parser_steps > 6000 or len(args.seeds) > 5 or
            len(args.seeds) != len(set(args.seeds)) or args.training_pairs > 8192 or args.evaluation_pairs > 2048 or
            args.batch_size > 128):
        parser.error("bounded probe limits: <=256 entities, <=10000 knowledge/6000 parser steps, <=5 distinct seeds, <=8192/2048 pairs, batch <=128")
    torch.set_num_threads(args.threads)
    torch.set_num_interop_threads(1)
    args.work.mkdir(parents=True, exist_ok=True)
    if args.worker:
        directory = args.work / f"seed-{args.seed}"
        directory.mkdir(exist_ok=True)
        if args.worker == "train":
            train_seed(args, directory)
        else:
            evaluate_seed(args, directory)
    else:
        orchestrate(args)


if __name__ == "__main__":
    main()
