#!/usr/bin/env python3
"""Bounded capacity/cost probe; generated kernels do not establish model quality."""

import argparse
import contextlib
import gc
import hashlib
import json
import os
import platform
import random
import resource
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import torch
from torch import nn

from ring_memory_model import RingMemory, TensorMemoryStore
from transformer_energy_bench import PackageEnergy, SudoPackageEnergy


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BACKENDS = ("dense", "tensor_full", "tensor_sparse", "koutendb_memory",
                    "koutendb_disk_warm", "koutendb_disk_advised")
SINGLE_COLD_BACKENDS = ("dense_disk_single_advised", "koutendb_disk_single_advised")
BACKENDS = DEFAULT_BACKENDS + SINGLE_COLD_BACKENDS


def memory_parameters(width, rings, slots, key_dim=16):
    return width * key_dim + rings * key_dim + rings * slots * (key_dim + width) + width * width + width


def dense_layer(width, parameters, device=None):
    intermediate = max(1, round((parameters - width) / (2 * width + 1)))
    return nn.Sequential(nn.Linear(width, intermediate, device=device), nn.GELU(),
                         nn.Linear(intermediate, width, device=device)).eval()


def tree_bytes(directory):
    return sum(p.stat().st_size for p in directory.rglob("*") if p.is_file())


def check_budget(directory, budget):
    size = tree_bytes(directory)
    # Leave substantial room for buffered close/metadata writes after this check.
    if size > budget - 32 * 1024**2:
        raise RuntimeError("temporary data approached the disk budget; stopping and removing it")
    return size


def proc_io():
    path = Path("/proc/self/io")
    if not path.exists():
        return {}
    return {key: int(value) for key, value in (line.split(":") for line in path.read_text().splitlines())}


def advise_evict(files):
    """Request eviction of these experiment files only; never drop system caches."""
    if not hasattr(os, "posix_fadvise") or not hasattr(os, "POSIX_FADV_DONTNEED"):
        raise RuntimeError("file-specific cache advice is not supported on this platform")
    for path in files:
        fd = os.open(path, os.O_RDONLY)
        try:
            os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        finally:
            os.close(fd)


def inputs(args):
    generator = torch.Generator().manual_seed(args.seed + 1)
    # Two latent reads per request, matching the trained model. No oracle rings.
    return torch.randn(args.questions, 2, args.width, generator=generator)


def new_memory(args, allocate_tables=True):
    torch.manual_seed(args.seed)
    return RingMemory(args.width, rings=args.rings, slots=args.slots,
                      allocate_tables=allocate_tables).eval()


def prepare(args):
    memory, hidden = new_memory(args), inputs(args)
    with torch.inference_mode():
        expected = torch.cat([memory(h[None]) for h in hidden])
    state = {key: value for key, value in memory.state_dict().items()
             if key not in ("keys", "values")}
    torch.save({"routing": state, "expected": expected}, args.case / "routing.pt")
    peak = 0

    def progress(records):
        nonlocal peak
        peak = max(peak, check_budget(args.case, args.disk_budget_mib * 1024**2))
        if records % 32768 == 0:
            print(f"  exported {records}/{args.rings * args.slots} records", flush=True)

    store = TensorMemoryStore(args.library, args.case / "db", memory, disk_backed=True, progress=progress)
    store.close()
    if args.with_dense_snapshot:
        torch.manual_seed(args.seed)
        dense = dense_layer(args.width, memory_parameters(args.width, args.rings, args.slots))
        torch.save(dense.state_dict(), args.case / "dense.pt")
        del dense
    # Flush only the generated files before cache advice in later workers.
    for path in args.case.rglob("*"):
        if path.is_file():
            fd = os.open(path, os.O_RDONLY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
    peak = max(peak, check_budget(args.case, args.disk_budget_mib * 1024**2))
    return {"temporary_bytes": peak, "records": args.rings * args.slots}


def measure(args):
    hidden = inputs(args)
    parameters = memory_parameters(args.width, args.rings, args.slots)
    store = None
    with contextlib.ExitStack() as stack, torch.inference_mode():
        if args.worker in ("dense", "dense_disk_single_advised"):
            torch.manual_seed(args.seed)
            layer = dense_layer(args.width, parameters)
            parity = None
            stats = None
        else:
            is_db = args.worker.startswith("koutendb")
            layer = new_memory(args, allocate_tables=not is_db)
            reference = torch.load(args.case / "routing.pt", weights_only=True)
            if is_db:
                layer.load_state_dict(reference["routing"])
                layer.eval()
                store = TensorMemoryStore.open_snapshot(args.library, args.case / "db", args.width,
                    args.rings, disk_backed=args.worker != "koutendb_memory")
                stack.callback(store.close)
                layer.store, layer.backend = store, "koutendb"
            else:
                layer.backend = args.worker
            actual = torch.cat([layer(h[None]) for h in hidden])
            expected = reference["expected"]
            torch.testing.assert_close(actual, expected, atol=3e-6, rtol=3e-5)
            parity = float((actual - expected).abs().max())
            stats = dict(layer.last_stats)
        for h in hidden[:2]:
            layer(h[None])
        energy = SudoPackageEnergy() if args.sudo_energy else PackageEnergy()
        stack.callback(energy.close)
        if args.require_energy and not energy.status["available"]:
            raise RuntimeError(f"energy required: {energy.status['reason']}")
        files = ([args.case / "dense.pt"] if args.worker == "dense_disk_single_advised" else
                 [p for p in (args.case / "db").rglob("*") if p.is_file()])
        samples = []
        for repeat in range(args.rounds):
            if args.worker in SINGLE_COLD_BACKENDS or args.worker == "koutendb_disk_advised":
                # One nonrepeating pass after each advice request; do not mix a
                # cold first pass with thousands of warm repeated questions.
                if args.worker == "dense_disk_single_advised":
                    # Remove old mappings before file-specific eviction advice.
                    # Map weights back without reading tensor contents; faults
                    # and storage transfers then occur inside the forward timer.
                    layer = None
                    gc.collect()
                advise_evict(files)
                if args.worker == "dense_disk_single_advised":
                    layer = dense_layer(args.width, parameters, device="meta")
                    layer.load_state_dict(torch.load(args.case / "dense.pt", weights_only=True, mmap=True), assign=True)
            timed_inputs = hidden[repeat % len(hidden):repeat % len(hidden) + 1] if args.worker in SINGLE_COLD_BACKENDS else hidden
            before_io, before_usage = proc_io(), resource.getrusage(resource.RUSAGE_SELF)
            before = energy.read()
            wall, cpu = time.perf_counter(), time.process_time()
            count = 0
            while True:
                for h in timed_inputs:
                    layer(h[None])
                    count += 1
                if args.worker in SINGLE_COLD_BACKENDS or args.worker == "koutendb_disk_advised" or time.perf_counter() - wall >= args.min_block_seconds:
                    break
            elapsed, consumed = time.perf_counter() - wall, time.process_time() - cpu
            joules = energy.joules(before, energy.read())
            after_io, after_usage = proc_io(), resource.getrusage(resource.RUSAGE_SELF)
            samples.append({"questions": count, "wall_ms": elapsed * 1000 / count,
                            "cpu_ms": consumed * 1000 / count,
                            "package_j": None if joules is None else joules / count,
                            "storage_read_bytes_per_question": (after_io.get("read_bytes", 0) - before_io.get("read_bytes", 0)) / count,
                            "major_faults": after_usage.ru_majflt - before_usage.ru_majflt})
        summary = {key: None if samples[0][key] is None else statistics.median(s[key] for s in samples)
                   for key in ("wall_ms", "cpu_ms", "package_j", "storage_read_bytes_per_question")}
        return {"backend": args.worker, "parameter_count": sum(p.numel() for p in layer.parameters()),
                "summary": summary, "samples": samples, "energy": energy.status,
                "max_abs_read_difference": parity, "access_counts_per_question": stats,
                "peak_process_rss_kib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}


def run_worker(args, case, rings, slots, worker, output):
    command = [sys.executable, str(Path(__file__).resolve()), "--worker", worker,
               "--case", str(case), "--worker-output", str(output), "--work", str(args.work),
               "--library", str(args.library), "--width", str(args.width), "--rings", str(rings),
               "--slots", str(slots), "--questions", str(args.questions), "--seed", str(args.seed),
               "--rounds", str(args.rounds), "--threads", str(args.threads),
               "--min-block-seconds", str(args.min_block_seconds),
               "--disk-budget-mib", str(args.disk_budget_mib)]
    if args.sudo_energy:
        command.append("--sudo-energy")
    if args.require_energy:
        command.append("--require-energy")
    if "dense_disk_single_advised" in args.backends:
        command.append("--with-dense-snapshot")
    started = time.perf_counter()
    subprocess.run(command, check=True, timeout=600)
    result = json.loads(output.read_text())
    result["worker_wall_seconds_including_setup"] = time.perf_counter() - started
    return result


def orchestrate(args):
    cases, peak = [], 0
    configurations = [(f"rings-{r}", r, 32) for r in args.ring_counts]
    if args.include_wide_ring:
        configurations.append(("wide-rings", 16, max(args.ring_counts) * 2))
    for name, rings, slots in configurations:
        parameters = memory_parameters(args.width, rings, slots)
        if parameters * 4 > 64 * 1024**2:
            raise ValueError("this bounded probe permits at most 64 MiB of logical memory parameters per case")
    for name, rings, slots in configurations:
        print(f"Preparing {name}: {memory_parameters(args.width, rings, slots)*4/1024**2:.3f} MiB parameters", flush=True)
        with tempfile.TemporaryDirectory(prefix="capacity-data-", dir=args.work) as directory:
            case = Path(directory)
            prep = run_worker(args, case, rings, slots, "prepare", case / "prepare.json")
            peak = max(peak, prep["temporary_bytes"])
            order = list(args.backends)
            random.Random(args.seed + rings + slots).shuffle(order)
            results = {}
            for backend in order:
                print(f"  measuring {name} / {backend}", flush=True)
                result = run_worker(args, case, rings, slots, backend, case / "worker.json")
                results[backend] = result
                print(f"    {result['summary']}", flush=True)
                peak = max(peak, check_budget(case, args.disk_budget_mib * 1024**2))
            cases.append({"case": name, "rings": rings, "slots_per_ring": slots,
                          "memory_parameters": memory_parameters(args.width, rings, slots),
                          "logical_parameter_bytes": memory_parameters(args.width, rings, slots) * 4,
                          "db_snapshot_bytes": prep["temporary_bytes"], "results": results})
            (args.work / f"{name}.json").write_text(json.dumps(cases[-1], indent=2) + "\n")
        # The context deletes the snapshot before the next case is created.
        print(f"  temporary snapshot for {name} removed", flush=True)
    cpu = platform.processor()
    if Path("/proc/cpuinfo").exists():
        cpu = next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                    if line.startswith("model name")), cpu)
    report = {"scope": "generated_knowledge_layer_capacity_cost_not_quality_equivalence",
              "settings": {"seed": args.seed, "width": args.width, "questions": args.questions,
                           "rounds": args.rounds, "threads": args.threads, "min_block_seconds": args.min_block_seconds},
              "runtime": {"torch": torch.__version__, "python": platform.python_version(), "cpu": cpu},
              "cases": cases, "peak_temporary_bytes_observed": peak,
              "disk_budget_bytes": args.disk_budget_mib * 1024**2,
              "temporary_snapshots_remaining": len(list(args.work.glob("capacity-data-*"))),
              "sha256": {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                         for name in ("ring_memory_capacity_bench.py", "ring_memory_model.py", "rag_energy_capi.py")},
              "library_sha256": hashlib.sha256(args.library.read_bytes()).hexdigest(),
              "limitations": ["Random kernels measure computational cost, not learned knowledge capacity or equal answer quality.",
                              "Two latent reads per question; only the knowledge layer is timed.",
                              "Actual table data fits in RAM; cache advice is not a real RAM-overflow experiment.",
                              "Advised disk runs use one pass after file-specific eviction advice; single_advised backends use one question per round.",
                              "Dense single-advised weights use a fresh mmap after advice; mapping setup is outside timing, page faults and transfers are inside.",
                              "Dense weights and tensor tables are warm; allocation, DB export and open are excluded from timing.",
                              "Separate workers prevent another backend's tensors from inflating the resident DB workload.",
                              "Read parity is checked for memory backends; dense and memory kernels implement different functions.",
                              "No 12B/300B model was downloaded or trained; no data-center energy extrapolation."]}
    (args.work / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Results saved; temporary snapshots removed. Peak generated data: {peak / 1024**2:.1f} MiB", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=ROOT / ".tmp/ring-memory-capacity")
    parser.add_argument("--library", type=Path, default=ROOT / "lib/libkoutendb.so")
    parser.add_argument("--ring-counts", nargs="+", type=int, default=[16, 64, 256, 1024, 4096])
    parser.add_argument("--include-wide-ring", action="store_true")
    parser.add_argument("--backends", nargs="+", choices=BACKENDS, default=list(DEFAULT_BACKENDS))
    parser.add_argument("--width", type=int, default=64)
    parser.add_argument("--questions", type=int, default=64)
    parser.add_argument("--seed", type=int, default=731)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--min-block-seconds", type=float, default=.2)
    parser.add_argument("--disk-budget-mib", type=int, default=256)
    parser.add_argument("--sudo-energy", action="store_true")
    parser.add_argument("--require-energy", action="store_true")
    parser.add_argument("--worker", choices=("prepare",) + BACKENDS, help=argparse.SUPPRESS)
    parser.add_argument("--case", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--worker-output", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--rings", type=int, default=16, help=argparse.SUPPRESS)
    parser.add_argument("--slots", type=int, default=32, help=argparse.SUPPRESS)
    parser.add_argument("--with-dense-snapshot", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    args.work, args.library = args.work.resolve(), args.library.resolve()
    if not args.work.is_relative_to(ROOT / ".tmp"):
        parser.error("keep generated data inside this project's .tmp directory on the project drive")
    if (min(args.width, args.questions, args.rounds, args.threads, args.rings, args.slots, *args.ring_counts) < 1 or
            not 64 <= args.disk_budget_mib <= 512 or not 0 < args.min_block_seconds <= 5):
        parser.error("positive counts, a 64..512 MiB disk budget and a block duration <=5s are required")
    args.work.mkdir(parents=True, exist_ok=True)
    if args.worker and (args.case is None or not args.case.resolve().is_relative_to(args.work)):
        parser.error("worker data must be inside the selected project work directory")
    torch.set_num_threads(args.threads)
    torch.set_num_interop_threads(1)
    if args.worker:
        result = prepare(args) if args.worker == "prepare" else measure(args)
        args.worker_output.write_text(json.dumps(result, indent=2) + "\n")
    else:
        if shutil.disk_usage(args.work).free < args.disk_budget_mib * 1024**2:
            parser.error("insufficient free space for the bounded experiment")
        orchestrate(args)


if __name__ == "__main__":
    main()
