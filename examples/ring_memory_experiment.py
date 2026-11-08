#!/usr/bin/env python3
"""Train and evaluate an internal ring-memory model, not an external RAG pipeline."""

import argparse
import contextlib
import copy
import hashlib
import json
import platform
import random
import statistics
import tempfile
import time
from pathlib import Path

import torch
from torch import nn

from ring_memory_data import encode, make_task
from ring_memory_model import RingMemory, TaskModel, TensorMemoryStore
from transformer_energy_bench import PackageEnergy, SudoPackageEnergy


def accuracy(model, rows, vocabulary, batch_size=64):
    counts = {}
    model.eval()
    with torch.inference_mode():
        for start in range(0, len(rows), batch_size):
            batch = rows[start:start + batch_size]
            ids, labels = encode(batch, vocabulary)
            correct = model(ids).argmax(-1).eq(labels).tolist()
            for row, hit in zip(batch, correct):
                numerator, denominator = counts.get(row["kind"], (0, 0))
                counts[row["kind"]] = (numerator + int(hit), denominator + 1)
    return {kind: yes / count for kind, (yes, count) in counts.items()}


def macro_accuracy(scores):
    return statistics.mean(scores.values())


def build_models(config, vocabulary, classes, seed):
    models = {}
    for kind in ("dense", "ring"):
        torch.manual_seed(seed)
        models[kind] = TaskModel(vocabulary, classes, **config, kind=kind)
    # Same initial shared backbone/classifier, not merely equal hyperparameters.
    shared = models["dense"].state_dict()
    models["ring"].load_state_dict({key: value for key, value in shared.items()
                                   if not key.startswith("knowledge.")}, strict=False)
    return models


def role_targets(rows):
    pairs = [[row["facts"][0], row["facts"][-1]] for row in rows]
    entities = torch.tensor([[a[0], b[0]] for a, b in pairs])
    attributes = torch.tensor([[a[1], b[1]] for a, b in pairs])
    operation = torch.tensor([int(row["kind"] == "composition") for row in rows])
    return entities, attributes, operation


def parser_accuracy(model, rows, vocabulary):
    model.eval()
    correct = [0, 0, 0]
    totals = [0, 0, 0]
    with torch.inference_mode():
        for start in range(0, len(rows), 64):
            batch = rows[start:start + 64]
            ids, _ = encode(batch, vocabulary)
            targets = role_targets(batch)
            predictions = model.parser_logits(ids)
            for i, (prediction, target) in enumerate(zip(predictions, targets)):
                correct[i] += int(prediction.argmax(-1).eq(target).sum())
                totals[i] += target.numel()
    return {name: yes / total for name, yes, total in zip(("entity", "attribute", "operation"), correct, totals)}


def train(args, output_dir, model_builder=build_models):
    parser_source = (torch.load(args.parser_checkpoint, map_location="cpu", weights_only=True)
                     if args.parser_checkpoint else None)
    task = parser_source["task"] if parser_source else make_task(args.seed, args.entities, args.values, args.training_pairs)
    if parser_source and (task["seed"] != args.seed or task["entities"] != args.entities or
                          task["values"] != args.values or len(task["train_composition"]) != args.training_pairs):
        raise ValueError("parser source must have the same seed, entity/value counts and training-pair count")
    config = {"width": args.width, "rings": args.rings, "slots": args.slots, "entities": task["parser_entities"]}
    models = model_builder(config, len(task["vocabulary"]), args.values + 2, args.seed)
    rng = random.Random(args.seed)
    parser_model = next(iter(models.values()))
    parser_parameters = [p for name, p in parser_model.named_parameters()
                         if name.startswith(("position.", "stem.", "entity_head.", "attribute_head.", "operation_head."))]
    parser_optimizer = torch.optim.AdamW(parser_parameters, lr=args.learning_rate, weight_decay=.001)
    parser_best, parser_state, parser_history = -1., None, []
    if parser_source:
        parser_state = {key: value for key, value in parser_source["models"]["dense"].items()
                        if key.startswith(("embedding.", "position.", "stem.", "entity_head.", "attribute_head.", "operation_head.", "semantic_codes"))}
        parser_history = parser_source["training"]["parser_history"]
        print("Reusing the common frozen language parser only; knowledge and answer heads start fresh.", flush=True)
    for step in range(1, (0 if parser_source else args.parser_steps) + 1):
        parser_model.train()
        rows = rng.choices(task["parser_training"], k=args.batch_size)
        ids, _ = encode(rows, task["vocabulary"])
        targets = role_targets(rows)
        outputs = parser_model.parser_logits(ids)
        loss = sum(nn.functional.cross_entropy(prediction.flatten(0, -2), target.flatten())
                   for prediction, target in zip(outputs[:2], targets[:2]))
        loss = loss + nn.functional.cross_entropy(outputs[2], targets[2])
        parser_optimizer.zero_grad(set_to_none=True)
        loss.backward()
        nn.utils.clip_grad_norm_(parser_parameters, 1.)
        parser_optimizer.step()
        if step % args.validate_every == 0 or step == args.parser_steps:
            scores = parser_accuracy(parser_model, task["validation"], task["vocabulary"])
            parser_history.append({"step": step, "loss": float(loss.detach()), "validation": scores})
            print(json.dumps({"language_parser": parser_history[-1]}), flush=True)
            value = statistics.mean(scores.values())
            if value > parser_best:
                parser_best = value
                parser_state = {key: tensor.clone() for key, tensor in parser_model.state_dict().items()
                                if key.startswith(("embedding.", "position.", "stem.", "entity_head.", "attribute_head.", "operation_head.", "semantic_codes"))}
    for model in models.values():
        model.load_state_dict(parser_state, strict=False)
        model.freeze_parser()
    optimizers = {kind: torch.optim.AdamW((p for p in model.parameters() if p.requires_grad),
                                         lr=args.learning_rate, weight_decay=.001)
                  for kind, model in models.items()}
    rng = random.Random(args.seed + 1)
    best = {kind: {"score": -1.} for kind in models}
    times = {kind: {"wall_seconds": 0., "cpu_seconds": 0.} for kind in models}
    history = []
    for step in range(1, args.steps + 1):
        rows = (rng.choices(task["train_single"], k=args.batch_size // 2) +
                rng.choices(task["train_composition"], k=args.batch_size - args.batch_size // 2))
        rng.shuffle(rows)
        ids, labels = encode(rows, task["vocabulary"])
        losses = {}
        for kind, model in models.items():
            model.train()
            if isinstance(model.knowledge, RingMemory):
                model.knowledge.soft_training = step <= args.soft_steps
            wall, cpu = time.perf_counter(), time.process_time()
            optimizers[kind].zero_grad(set_to_none=True)
            logits, fact_logits = model(ids, return_facts=True)
            role_entities, role_attributes, _ = role_targets(rows)
            fact_targets = torch.tensor([[task["world"][int(i)][int(a)] for i, a in zip(es, ats)]
                                         for es, ats in zip(role_entities, role_attributes)])
            loss = nn.functional.cross_entropy(logits, labels) + .5 * nn.functional.cross_entropy(
                fact_logits.flatten(0, 1), fact_targets.flatten())
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 1.)
            optimizers[kind].step()
            times[kind]["wall_seconds"] += time.perf_counter() - wall
            times[kind]["cpu_seconds"] += time.process_time() - cpu
            losses[kind] = float(loss.detach())
        if step % args.validate_every == 0 or step == args.steps:
            scores = {kind: accuracy(model, task["validation"], task["vocabulary"])
                      for kind, model in models.items()}
            for kind, model in models.items():
                value = macro_accuracy(scores[kind])
                if step > args.soft_steps and value > best[kind]["score"]:
                    best[kind] = {"score": value, "step": step,
                                  "state": copy.deepcopy(model.state_dict())}
            history.append({"step": step, "loss": losses, "validation": scores})
            print(json.dumps(history[-1]), flush=True)
    if any("state" not in entry for entry in best.values()):
        raise ValueError("training must include at least one validation after soft warmup")
    checkpoint = {"schema_version": 4, "task": task, "model_config": config, "seed": args.seed,
                  "models": {kind: entry["state"] for kind, entry in best.items()},
                  "training": {"steps": args.steps, "soft_steps": args.soft_steps,
                               "learning_rate": args.learning_rate, "batch_size": args.batch_size,
                               "times": times, "history": history, "parser_history": parser_history,
                               "parser_source_sha256": (hashlib.sha256(args.parser_checkpoint.read_bytes()).hexdigest()
                                                          if args.parser_checkpoint else None),
                               "selected_steps": {kind: entry["step"] for kind, entry in best.items()}}}
    torch.save(checkpoint, output_dir / "checkpoint.pt")
    return checkpoint


def benchmark(args, checkpoint, output_dir):
    task = checkpoint["task"]
    models = build_models(checkpoint["model_config"], len(task["vocabulary"]),
                          task["values"] + 2, checkpoint["seed"])
    for kind, model in models.items():
        model.load_state_dict(checkpoint["models"][kind])
        model.freeze_parser()
        model.eval()
    ring = models["ring"]
    quality = {"dense": accuracy(models["dense"], task["test"], task["vocabulary"])}
    for backend in ("tensor_full", "tensor_sparse", "ablated"):
        ring.knowledge.backend = backend
        quality[backend] = accuracy(ring, task["test"], task["vocabulary"])
    samples, rng = {}, random.Random(checkpoint["seed"])
    with tempfile.TemporaryDirectory(prefix="koutendb-neural-memory-", dir=output_dir) as directory, contextlib.ExitStack() as stack:
        def check_budget(_completed):
            if args.disk_budget_mib:
                size = sum(p.stat().st_size for p in output_dir.rglob("*") if p.is_file())
                if size > (args.disk_budget_mib - 16) * 1024**2:
                    raise RuntimeError("experiment approached its temporary-file budget")

        store = TensorMemoryStore(args.library, Path(directory), ring.knowledge, progress=check_budget)
        stack.callback(store.close)
        ring.knowledge.store = store
        ring.knowledge.backend = "koutendb"
        # Validate real DB reads on all test questions, without giving DB code labels.
        quality["koutendb"] = accuracy(ring, task["test"], task["vocabulary"], batch_size=1)
        parity_max, parity_mismatches = 0., 0
        with torch.inference_mode():
            for row in task["test"]:
                ids, _ = encode([row], task["vocabulary"])
                ring.knowledge.backend = "tensor_sparse"
                expected = ring(ids)
                ring.knowledge.backend = "koutendb"
                actual = ring(ids)
                parity_max = max(parity_max, float((expected - actual).abs().max()))
                parity_mismatches += int(expected.argmax(-1).item() != actual.argmax(-1).item())
        if parity_mismatches:
            raise RuntimeError(f"DB/reference prediction mismatch on {parity_mismatches} test questions")
        print(f"Test quality: {quality}; DB/reference max logit difference={parity_max:.6g}", flush=True)
        energy = SudoPackageEnergy() if args.sudo_energy else PackageEnergy()
        stack.callback(energy.close)
        if args.require_energy and not energy.status["available"]:
            raise RuntimeError(f"Energy measurement required: {energy.status['reason']}")
        # Pre-encode equally for every backend. Measure model execution, including
        # learned routing, memory read/transfer and output, not Python tokenization.
        by_kind = {kind: [row for row in task["test"] if row["kind"] == kind]
                   for kind in ("single", "composition")}
        timing_rows = []
        for i in range(max(map(len, by_kind.values()))):
            for group in by_kind.values():
                if i < len(group) and len(timing_rows) < args.timing_questions:
                    timing_rows.append(group[i])
        evaluation = [encode(timing_rows[start:start + args.inference_batch], task["vocabulary"])[0]
                      for start in range(0, len(timing_rows), args.inference_batch)]
        backends = ("dense", "tensor_full", "tensor_sparse", "koutendb")
        with torch.inference_mode():
            for repeat in range(args.rounds):
                order = [(backend, scope) for backend in backends for scope in ("model", "knowledge_layer")]
                rng.shuffle(order)
                for backend, scope in order:
                    model = models["dense"] if backend == "dense" else ring
                    if backend != "dense":
                        ring.knowledge.backend = backend
                    inputs = evaluation if scope == "model" else [model.semantic_input(ids)[0] for ids in evaluation]
                    execute = model if scope == "model" else model.knowledge
                    for value in inputs[:2]:
                        execute(value)
                    before = energy.read()
                    wall, cpu = time.perf_counter(), time.process_time()
                    requests = 0
                    while True:
                        for value in inputs:
                            execute(value)
                            requests += len(value)
                        if time.perf_counter() - wall >= args.min_block_seconds:
                            break
                    elapsed, cpu_elapsed = time.perf_counter() - wall, time.process_time() - cpu
                    joules = energy.joules(before, energy.read())
                    samples.setdefault(f"{backend}/{scope}", []).append({"requests": requests,
                        "wall_ms": elapsed * 1000 / requests, "cpu_ms": cpu_elapsed * 1000 / requests,
                        "package_j": None if joules is None else joules / requests})
                print(f"timing round {repeat + 1}/{args.rounds} complete", flush=True)
        # Record known algorithmic access counts; do not label these hardware counters.
        access = {}
        with torch.inference_mode():
            for backend in ("tensor_full", "tensor_sparse", "koutendb"):
                ring.knowledge.backend = backend
                ring(evaluation[0])
                access[backend] = dict(ring.knowledge.last_stats)
        all_summaries = {backend: {key: None if rows[0][key] is None else
                                statistics.median(row[key] for row in rows)
                               for key in ("wall_ms", "cpu_ms", "package_j")}
                     for backend, rows in samples.items()}
        summaries = {backend: all_summaries[f"{backend}/model"] for backend in backends}
        layer_summaries = {backend: all_summaries[f"{backend}/knowledge_layer"] for backend in backends}
    Path(str(directory) + ".kouten-dir.lock").unlink(missing_ok=True)
    report = {"scope": "trained_internal_latent_memory_prototype", "quality": quality,
              "test_counts": {kind: sum(row["kind"] == kind for row in task["test"])
                              for kind in ("single", "composition")},
              "test_text_overlap_with_training": len({r["text"] for r in task["test"]} &
                                                       {r["text"] for r in task["train_single"] + task["train_composition"]}),
              "test_text_overlap_with_parser_training": len({r["text"] for r in task["test"]} &
                                                              {r["text"] for r in task["parser_training"]}),
              "model_config": checkpoint["model_config"],
              "parameter_counts": {kind: {"total": sum(p.numel() for p in model.parameters()),
                                           "trainable": sum(p.numel() for p in model.parameters() if p.requires_grad),
                                           "knowledge_layer": sum(p.numel() for p in model.knowledge.parameters())}
                                   for kind, model in models.items()},
              "training": checkpoint["training"], "energy": energy.status,
              "parity": {"max_logit_error": parity_max, "prediction_mismatches": parity_mismatches},
              "access_counts": access, "summaries": summaries, "samples": samples,
              "access_count_batch_size": len(evaluation[0]),
              "knowledge_layer_summaries": layer_summaries,
              "runtime": {"torch": torch.__version__, "python": platform.python_version(),
                          "platform": platform.platform(), "threads": args.threads,
                          "rounds": args.rounds, "min_block_seconds": args.min_block_seconds},
              "timing_workload": {"questions": len(timing_rows), "batch_size": args.inference_batch,
                                  "kinds": {kind: sum(row["kind"] == kind for row in timing_rows)
                                            for kind in by_kind}},
              "implementation_sha256": {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                                         for name in ("ring_memory_model.py", "ring_memory_data.py", "ring_memory_experiment.py")},
              "checkpoint_sha256": hashlib.sha256((output_dir / "checkpoint.pt").read_bytes()).hexdigest(),
              "library_sha256": hashlib.sha256(args.library.read_bytes()).hexdigest(),
              "limitations": ["Synthetic relational classification, not a general-purpose language model.",
                              "Single-fact test uses unseen phrasing of learned facts; composition uses held-out fact pairs.",
                              "A shared parser learns entity/attribute roles without fact values, then is frozen in both models.",
                              "The model uses continuous semantic probabilities, not oracle IDs or ring labels at inference.",
                              "Ring memory replaces one knowledge layer, not all weights.",
                              "Training uses a dense straight-through surrogate; no sparse-training energy claim.",
                              "Access counts are algorithmic counts, not measured DRAM traffic or isolated weight-access time.",
                              "Reference tensor tables remain resident for comparison; no deployment RAM-saving claim.",
                              "Initialization/export/training/tokenization are outside the timed inference blocks.",
                              "CPU package energy is not data-center or whole-system energy."]}
    (output_dir / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"quality": quality, "summaries": summaries,
                      "knowledge_layer_summaries": layer_summaries}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=Path(".tmp/ring-memory-model"))
    parser.add_argument("--library", type=Path, default=Path("lib/libkoutendb.so"))
    parser.add_argument("--train", action="store_true")
    parser.add_argument("--parser-checkpoint", type=Path,
                        help="reuse only the frozen parser and task from an existing experiment")
    parser.add_argument("--disk-budget-mib", type=int, default=0,
                        help="optional file budget with a 16 MiB stopping margin")
    parser.add_argument("--seed", type=int, default=731)
    parser.add_argument("--entities", type=int, default=32)
    parser.add_argument("--values", type=int, default=8)
    parser.add_argument("--training-pairs", type=int, default=1024)
    parser.add_argument("--width", type=int, default=64)
    parser.add_argument("--rings", type=int, default=16)
    parser.add_argument("--slots", type=int, default=32)
    parser.add_argument("--steps", type=int, default=1500)
    parser.add_argument("--parser-steps", type=int, default=1000)
    parser.add_argument("--soft-steps", type=int, default=250)
    parser.add_argument("--learning-rate", type=float, default=.003)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--validate-every", type=int, default=100)
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--inference-batch", type=int, default=1)
    parser.add_argument("--timing-questions", type=int, default=32)
    parser.add_argument("--min-block-seconds", type=float, default=.5)
    parser.add_argument("--sudo-energy", action="store_true")
    parser.add_argument("--require-energy", action="store_true")
    args = parser.parse_args()
    if min(args.entities, args.values, args.training_pairs, args.width, args.rings, args.slots,
           args.steps, args.parser_steps, args.batch_size, args.validate_every, args.threads, args.rounds, args.timing_questions, args.inference_batch) < 1:
        parser.error("counts must be positive")
    if args.entities < 32 or args.width % 4 or not 0 <= args.soft_steps < args.steps or not 0 < args.min_block_seconds <= 10:
        parser.error("need >=32 entities, width divisible by 4, warmup below total steps and a positive block duration <=10s")
    if args.disk_budget_mib and args.disk_budget_mib < 32:
        parser.error("a file budget must be at least 32 MiB")
    torch.set_num_threads(args.threads)
    torch.set_num_interop_threads(1)
    args.work.mkdir(parents=True, exist_ok=True)
    if args.train or not (args.work / "checkpoint.pt").exists():
        checkpoint = train(args, args.work)
    else:
        checkpoint = torch.load(args.work / "checkpoint.pt", map_location="cpu", weights_only=True)
        if checkpoint.get("schema_version") != 4:
            parser.error("checkpoint architecture changed; run again with --train")
    benchmark(args, checkpoint, args.work)


if __name__ == "__main__":
    main()
