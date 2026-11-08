#!/usr/bin/env python3
"""Matched training and CPU inference comparison of flat/product ring routers.

No external model/data downloads. Uses the synthetic task and optional shared
language-parser checkpoint from ring_memory_quality_bench.py.
"""

import argparse
import contextlib
import hashlib
import json
import platform
import random
import statistics
import tempfile
import time
from pathlib import Path

import torch
from torch.nn import functional as F

from ring_memory_data import encode
from ring_memory_experiment import accuracy, train
from ring_memory_model import TaskModel, TensorMemoryStore
from ring_memory_router import ProductRingRouter
from transformer_energy_bench import PackageEnergy, SudoPackageEnergy

ROOT = Path(__file__).resolve().parents[1]


def build_models(config, vocabulary, classes, seed):
    models = {}
    for kind in ("flat", "product"):
        torch.manual_seed(seed)
        models[kind] = TaskModel(vocabulary, classes, **config, router_kind=kind)
    # Copy every common initial tensor, including local memory keys/values,
    # semantic codes, query/output projections and answer heads. Only the
    # representative-key family differs; neither model receives trained facts.
    common = {key: value for key, value in models["flat"].state_dict().items()
              if key != "knowledge.ring_keys"}
    missing = models["product"].load_state_dict(common, strict=False)
    if set(missing.missing_keys) != {"knowledge.product_router.left", "knowledge.product_router.right"} or missing.unexpected_keys:
        raise RuntimeError("unmatched common model initialization")
    return models


def check_budget(args, _completed=None):
    size = sum(p.stat().st_size for p in args.work.rglob("*") if p.is_file())
    if size > (args.disk_budget_mib - 16) * 1024**2:
        raise RuntimeError("experiment approached its temporary-file budget")
    return size


def measure(execute, inputs, seconds, energy):
    for value in inputs[:2]:
        execute(value)
    before = energy.read()
    wall, cpu, requests = time.perf_counter(), time.process_time(), 0
    while True:
        for value in inputs:
            execute(value)
            requests += len(value)
        if time.perf_counter() - wall >= seconds:
            break
    elapsed, cpu_elapsed = time.perf_counter() - wall, time.process_time() - cpu
    joules = energy.joules(before, energy.read())
    return {"requests": requests, "wall_ms": elapsed * 1000 / requests,
            "cpu_ms": cpu_elapsed * 1000 / requests,
            "package_j": None if joules is None else joules / requests}


def medians(samples):
    return {name: {key: None if rows[0][key] is None else statistics.median(row[key] for row in rows)
                   for key in ("wall_ms", "cpu_ms", "package_j")}
            for name, rows in samples.items()}


def router_scaling(args, energy):
    """Same Cartesian key family: implicit router versus fast expanded matmul.

    Large virtual ring counts allocate representative keys only, NOT local
    value tables. They are not evidence of a trained model at that capacity.
    """
    results, rng = [], random.Random(args.seed)
    with torch.inference_mode():
        for rings in (1024, 4096, 65536, 262144):
            torch.manual_seed(args.seed)
            router = ProductRingRouter(rings, 16).eval()
            keys = torch.cat((router.eval_left[:, None, :].expand(-1, router.columns, -1),
                              router.eval_right[None, :, :].expand(router.rows, -1, -1)), -1).flatten(0, 1) / 2**.5
            queries = [F.normalize(torch.randn(2, 16), dim=-1) for _ in range(32)]
            def expanded(value):
                return (value @ keys.T).topk(2, dim=-1)
            mismatches, max_error = 0, 0.
            for value in queries:
                actual, expected = router.topk(value, 2), expanded(value)
                mismatches += int((actual[1] != expected.indices).any(-1).sum())
                max_error = max(max_error, float((actual[0] - expected.values).abs().max()))
            if mismatches:
                raise RuntimeError("router scaling inputs hit a numerically ambiguous selection; inspect before timing")
            samples = {}
            for _ in range(args.rounds):
                order = ["expanded", "product"]
                rng.shuffle(order)
                for name in order:
                    execute = expanded if name == "expanded" else lambda q: router.topk(q, 2)
                    samples.setdefault(name, []).append(measure(execute, queries, args.min_block_seconds, energy))
            results.append({"rings": rings, "shape": [router.rows, router.columns],
                            "expanded_key_bytes": keys.numel() * keys.element_size(),
                            "product_key_bytes": sum(p.numel() * p.element_size() for p in router.parameters()),
                            "access_counts_per_query": {"expanded": {"router_keys_scored": rings},
                                                        "product": router.access_counts(1, 2)},
                            "selection_mismatches": mismatches, "max_score_error": max_error,
                            "summaries_per_query": medians(samples), "samples": samples})
            print(f"Router-only scaling: {rings} virtual rings complete", flush=True)
    return results


def benchmark(args, checkpoint):
    task = checkpoint["task"]
    models = build_models(checkpoint["model_config"], len(task["vocabulary"]), task["values"] + 2, checkpoint["seed"])
    for name, model in models.items():
        model.load_state_dict(checkpoint["models"][name])
        model.freeze_parser()
        model.eval()
    quality, parity, samples, counts = {}, {}, {}, {}
    # Identical balanced, pre-tokenized single-question workload for both models.
    groups = [[row for row in task["test"] if row["kind"] == kind][:16]
              for kind in ("single", "composition")]
    timing_rows = [row for pair in zip(*groups) for row in pair]
    inputs = [encode([row], task["vocabulary"])[0] for row in timing_rows]
    rng = random.Random(args.seed)
    with contextlib.ExitStack() as stack, torch.inference_mode():
        energy = SudoPackageEnergy() if args.sudo_energy else PackageEnergy()
        stack.callback(energy.close)
        if args.require_energy and not energy.status["available"]:
            raise RuntimeError(f"Energy measurement required: {energy.status['reason']}")
        for name, model in models.items():
            quality[name] = {"tensor_sparse": accuracy(model, task["test"], task["vocabulary"])}
            directory = stack.enter_context(tempfile.TemporaryDirectory(prefix=f"{name}-db-", dir=args.work))
            stack.callback(Path(directory + ".kouten-dir.lock").unlink, missing_ok=True)
            store = TensorMemoryStore(args.library, Path(directory), model.knowledge,
                                      progress=lambda done: check_budget(args, done))
            stack.callback(store.close)
            model.knowledge.store = store
            mismatches, max_error, predictions = 0, 0., []
            for row in task["test"]:
                ids, labels = encode([row], task["vocabulary"])
                model.knowledge.backend = "tensor_sparse"
                expected = model(ids)
                model.knowledge.backend = "koutendb"
                actual = model(ids)
                predicted = int(actual.argmax(-1))
                predictions.append({"kind": row["kind"], "label": int(labels[0]), "prediction": predicted})
                mismatches += int(expected.argmax(-1).item() != predicted)
                max_error = max(max_error, float((actual - expected).abs().max()))
            if mismatches:
                raise RuntimeError(f"{name}: DB/reference prediction mismatch")
            quality[name]["koutendb"] = {kind: statistics.mean(row["prediction"] == row["label"] for row in predictions if row["kind"] == kind)
                                         for kind in ("single", "composition")}
            store.aggregation = "per_ring"
            quality[name]["koutendb_per_ring"] = accuracy(model, task["test"], task["vocabulary"])
            store.aggregation = "batched"
            parity[name] = {"prediction_mismatches": mismatches, "max_logit_error": max_error,
                            "test_questions": len(predictions)}
            model(inputs[0])
            counts[name] = dict(model.knowledge.last_stats)
            print(f"{name}: held-out quality {quality[name]}, DB parity {parity[name]}", flush=True)
        product = models["product"]
        # The mathematical reference is an intervention on the SAME trained
        # product model, not a substitute for separately trained flat accuracy.
        router = product.knowledge.product_router
        original = router.topk
        try:
            router.topk = router.full_topk
            quality["product"]["full_product_reference"] = accuracy(product, task["test"], task["vocabulary"])
        finally:
            router.topk = original
        for _ in range(args.rounds):
            order = [(name, backend, scope) for name in models for backend in ("tensor_sparse", "koutendb", "koutendb_per_ring")
                     for scope in ("model", "knowledge_layer")]
            rng.shuffle(order)
            for name, backend, scope in order:
                model = models[name]
                model.knowledge.backend = "koutendb" if backend.startswith("koutendb") else backend
                model.knowledge.store.aggregation = "per_ring" if backend == "koutendb_per_ring" else "batched"
                values = inputs if scope == "model" else [model.semantic_input(ids)[0] for ids in inputs]
                execute = model if scope == "model" else model.knowledge
                samples.setdefault(f"{name}/{backend}/{scope}", []).append(
                    measure(execute, values, args.min_block_seconds, energy))
            print("Whole-model timing round complete", flush=True)
        scaling = router_scaling(args, energy)
        peak_disk = check_budget(args)
    trained_texts = {r["text"] for r in task["train_single"] + task["train_composition"]}
    test_texts = {r["text"] for r in task["test"]}
    files = ("ring_memory_product_bench.py", "ring_memory_router.py", "ring_memory_model.py",
             "ring_memory_experiment.py", "ring_memory_data.py")
    report = {"scope": "matched_learned_flat_vs_product_ring_routing", "schema_version": 2,
              "plan": json.loads((args.work / "plan.json").read_text()),
              "model_config": checkpoint["model_config"], "training": checkpoint["training"],
              "quality": quality, "parity": parity,
              "test_counts": {kind: sum(r["kind"] == kind for r in task["test"]) for kind in ("single", "composition")},
              "test_text_overlap_with_knowledge_training": len(test_texts & trained_texts),
              "test_text_overlap_with_parser_training": len(test_texts & {r["text"] for r in task["parser_training"]}),
              "access_counts_per_question": counts, "timing_workload": {"single": 16, "composition": 16, "batch_size": 1},
              "db_aggregation": {"koutendb": "batched", "koutendb_per_ring": "original per-ring reference"},
              "summaries": medians(samples), "samples": samples, "router_only_scaling": scaling,
              "energy": energy.status, "work_bytes_with_db_snapshots": peak_disk,
              "runtime": {"torch": torch.__version__, "python": platform.python_version(),
                          "threads": args.threads, "rounds": args.rounds, "min_block_seconds": args.min_block_seconds},
              "checkpoint_sha256": hashlib.sha256((args.work / "checkpoint.pt").read_bytes()).hexdigest(),
              "library_sha256": hashlib.sha256(args.library.read_bytes()).hexdigest(),
              "implementation_sha256": {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest() for name in files},
              "limitations": ["Synthetic 384-fact classification by default, not a large language model.",
                              "Only routing is factorized; all local keys/values still exist and are resident in this comparison.",
                              "Product keys restrict the learned representative-key family; arbitrary flat checkpoints require retraining.",
                              "Training uses full scores and dense local memory; no sparse-training or training-energy claim.",
                              "Router-only large keyspaces are untrained and contain no corresponding local memory tables.",
                              "Algorithmic access counts are not measured DRAM or SSD traffic.",
                              "Single world/seed; quality differences need independent replications.",
                              "CPU package joules, if available, exclude GPU, whole-system and data-center energy.",
                              "Timing excludes initialization, DB export, tokenization and training; includes inference routing/read/output."]}
    (args.work / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"quality": quality, "summaries": report["summaries"], "energy": energy.status}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=ROOT / ".tmp/product-ring-memory")
    parser.add_argument("--library", type=Path, default=ROOT / "lib/libkoutendb.so")
    parser.add_argument("--parser-checkpoint", type=Path)
    parser.add_argument("--train", action="store_true")
    parser.add_argument("--seed", type=int, default=731)
    parser.add_argument("--entities", type=int, default=128)
    parser.add_argument("--values", type=int, default=8)
    parser.add_argument("--training-pairs", type=int, default=4096)
    parser.add_argument("--width", type=int, default=64)
    parser.add_argument("--rings", type=int, default=1024)
    parser.add_argument("--slots", type=int, default=32)
    parser.add_argument("--steps", type=int, default=1500)
    parser.add_argument("--parser-steps", type=int, default=3000)
    parser.add_argument("--soft-steps", type=int, default=250)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--learning-rate", type=float, default=.003)
    parser.add_argument("--validate-every", type=int, default=150)
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--min-block-seconds", type=float, default=.25)
    parser.add_argument("--disk-budget-mib", type=int, default=128)
    parser.add_argument("--sudo-energy", action="store_true")
    parser.add_argument("--require-energy", action="store_true")
    args = parser.parse_args()
    if (min(args.seed, args.entities, args.values, args.training_pairs, args.width, args.rings, args.slots,
            args.steps, args.parser_steps, args.batch_size, args.validate_every, args.threads, args.rounds) < 1 or
            args.width != 64 or args.entities > 128 or args.rings > 1024 or not 4 <= args.slots <= 32 or
            args.batch_size > 64 or args.values > 8 or args.training_pairs > 4096 or args.soft_steps < 0 or
            args.steps <= args.soft_steps or args.min_block_seconds <= 0 or args.learning_rate <= 0 or
            not 96 <= args.disk_budget_mib <= 512):
        parser.error("use bounded positive settings: width64, entities<=128, rings<=1024, slots4..32, budget96..512MiB")
    torch.set_num_threads(args.threads)
    args.work.mkdir(parents=True, exist_ok=True)
    check_budget(args)
    if args.train or not (args.work / "checkpoint.pt").exists():
        plan = {key: getattr(args, key) for key in ("seed", "entities", "values", "training_pairs", "width", "rings", "slots",
                                                  "steps", "soft_steps", "batch_size", "validate_every", "learning_rate")}
        plan.update({"selection": "best validation macro accuracy after warmup; held-out test opened after both models train",
                     "common_initialization": "all tensors except representative-key family",
                     "parser_source_sha256": hashlib.sha256(args.parser_checkpoint.read_bytes()).hexdigest() if args.parser_checkpoint else None})
        (args.work / "plan.json").write_text(json.dumps(plan, indent=2) + "\n")
        checkpoint = train(args, args.work, model_builder=build_models)
        checkpoint["comparison"] = "flat_vs_product"
        torch.save(checkpoint, args.work / "checkpoint.pt")
    else:
        checkpoint = torch.load(args.work / "checkpoint.pt", map_location="cpu", weights_only=True)
        if checkpoint.get("comparison") != "flat_vs_product":
            parser.error("use a separate work directory or --train for this comparison")
    check_budget(args)
    benchmark(args, checkpoint)


if __name__ == "__main__":
    main()
