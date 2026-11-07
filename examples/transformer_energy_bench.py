#!/usr/bin/env python3
"""Measure actual Transformer inference on prompts exported by KoutenDB.

Random weights and a corpus-local word/punctuation tokenizer measure compute,
not answer quality or production LLM tokens. No model download is required.
"""

import argparse
import contextlib
import json
import platform
import random
import re
import statistics
import subprocess
import time
from pathlib import Path

import torch
from torch import nn
from torch.nn import functional as F


VARIANTS = ("global", "routed", "global_same_budget")


class Block(nn.Module):
    def __init__(self, width, heads):
        super().__init__()
        self.heads = heads
        self.norm1 = nn.LayerNorm(width)
        self.qkv = nn.Linear(width, 3 * width)
        self.projection = nn.Linear(width, width)
        self.norm2 = nn.LayerNorm(width)
        self.ffn = nn.Sequential(nn.Linear(width, 4 * width), nn.GELU(),
                                 nn.Linear(4 * width, width))

    def forward(self, x, cache=None):
        batch, length, width = x.shape
        q, k, v = self.qkv(self.norm1(x)).chunk(3, dim=-1)
        q, k, v = [t.reshape(batch, length, self.heads, width // self.heads)
                   .transpose(1, 2) for t in (q, k, v)]
        if cache is not None:
            # Cached decoding handles one new position, with no future keys.
            if length != 1:
                raise ValueError("cached decoding expects one token")
            k = torch.cat((cache[0], k), dim=2)
            v = torch.cat((cache[1], v), dim=2)
        attention = F.scaled_dot_product_attention(
            q, k, v, dropout_p=0.0, is_causal=cache is None)
        x = x + self.projection(attention.transpose(1, 2).reshape(batch, length, width))
        return x + self.ffn(self.norm2(x)), (k, v)


class TinyTransformer(nn.Module):
    def __init__(self, vocab, max_length, width=128, heads=4, layers=2):
        super().__init__()
        self.token = nn.Embedding(vocab, width)
        self.position = nn.Embedding(max_length, width)
        self.blocks = nn.ModuleList([Block(width, heads) for _ in range(layers)])
        self.norm = nn.LayerNorm(width)
        self.output = nn.Linear(width, vocab, bias=False)

    def forward(self, ids, cache=None):
        offset = 0 if cache is None else cache[0][0].shape[2]
        positions = torch.arange(offset, offset + ids.shape[1])
        x = self.token(ids) + self.position(positions)
        updated = []
        for i, block in enumerate(self.blocks):
            x, kv = block(x, None if cache is None else cache[i])
            updated.append(kv)
        return self.output(self.norm(x[:, -1])), updated

    def generate(self, ids, count):
        logits, cache = self(ids)
        token = logits.argmax(dim=-1, keepdim=True)
        for _ in range(count - 1):
            logits, cache = self(token, cache)
            token = logits.argmax(dim=-1, keepdim=True)
        return token


class PackageEnergy:
    """Read package domains only; never add a parent and its core subdomain."""

    def __init__(self, root=Path("/sys/class/powercap")):
        self.zones = []
        errors = []
        seen = set()
        for path in sorted(root.glob("*")):
            try:
                if not (path / "name").read_text().strip().startswith("package-"):
                    continue
                resolved = path.resolve()
                if resolved in seen:
                    continue
                seen.add(resolved)
                maximum = int((path / "max_energy_range_uj").read_text())
                value = int((path / "energy_uj").read_text())
                if maximum <= 0 or not 0 <= value <= maximum:
                    raise ValueError("invalid energy counter range")
                self.zones.append((path, maximum))
            except FileNotFoundError:
                continue
            except (OSError, ValueError) as error:
                errors.append(f"{path.name}: {getattr(error, 'strerror', None) or str(error)}")
        # Partial package coverage would silently undercount a multi-socket host.
        if errors:
            self.zones = []
        self.status = {"available": bool(self.zones),
                       "domains": [p.name for p, _ in self.zones],
                       "reason": "; ".join(errors) if errors else
                       (None if self.zones else "no readable CPU package counters")}

    def read(self):
        return [int((path / "energy_uj").read_text()) for path, _ in self.zones]

    def joules(self, before, after):
        if not self.zones:
            return None
        # Blocks must be shorter than a full counter wrap. Defaults are subsecond.
        return sum((end - start) % maximum for start, end, (_, maximum)
                   in zip(before, after, self.zones)) / 1_000_000

    def close(self):
        pass


class SudoPackageEnergy(PackageEnergy):
    """Keep inference unprivileged; only a fixed read-only helper uses sudo."""

    def __init__(self):
        helper = Path(__file__).with_name("rapl_energy_reader.py").resolve()
        # System Python needs no PyTorch or user-site packages. sudo reads the
        # password directly from the user's terminal, never from our protocol.
        self.process = subprocess.Popen(
            ["sudo", "--", "/usr/bin/python3", "-I", str(helper)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        try:
            hello = self.receive()
            domains, ranges = hello["domains"], hello["ranges"]
            if not domains or len(domains) != len(ranges) or any(n <= 0 for n in ranges):
                raise RuntimeError("invalid energy helper handshake")
            self.zones = list(zip(domains, ranges))
            self.status = {"available": True, "domains": domains,
                           "reader": "sudo read-only helper", "reason": None}
        except BaseException:
            self.close()
            raise

    def receive(self):
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("energy helper exited; check the sudo message in your terminal")
        message = json.loads(line)
        if "error" in message:
            raise RuntimeError(message["error"])
        return message

    def read(self):
        self.process.stdin.write("read\n")
        self.process.stdin.flush()
        values = self.receive()["values"]
        if len(values) != len(self.zones):
            raise RuntimeError("incomplete energy helper reading")
        return values

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.process.stdout.close()


def tokenize(text):
    return re.findall(r"\w+|[^\w\s]", text, re.UNICODE)


def load_prompts(path):
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    groups = {variant: [] for variant in VARIANTS}
    for row in rows:
        if row["variant"] in groups:
            groups[row["variant"]].append(row)
    expected = None
    for variant, items in groups.items():
        items.sort(key=lambda row: row["query"])
        names = [row["query"] for row in items]
        if not names or len(set(names)) != len(names):
            raise ValueError(f"missing or duplicate queries for {variant}")
        if expected is not None and names != expected:
            raise ValueError("variants must contain identical query sets")
        expected = names
        if any(not row["prompt"] or not isinstance(row["target_recalled"], bool)
               for row in items):
            raise ValueError("prompts and boolean target_recalled fields are required")
    words = sorted({word for items in groups.values() for row in items
                    for word in tokenize(row["prompt"])})
    vocab = {word: i + 1 for i, word in enumerate(words)}
    tensors = {variant: [torch.tensor([[vocab[word] for word in tokenize(row["prompt"])]])
                         for row in items] for variant, items in groups.items()}
    if any(ids.shape[1] == 0 for items in tensors.values() for ids in items):
        raise ValueError("empty token sequences are not supported")
    return rows, groups, tensors, len(vocab) + 1


def measure(model, prompts, new_tokens, energy, min_seconds):
    before = energy.read()
    wall_start, cpu_start = time.perf_counter(), time.process_time()
    requests = 0
    while True:
        for ids in prompts:
            model.generate(ids, new_tokens)
            requests += 1
        if time.perf_counter() - wall_start >= min_seconds:
            break
    cpu_seconds = time.process_time() - cpu_start
    wall_seconds = time.perf_counter() - wall_start
    joules = energy.joules(before, energy.read())
    return {"requests": requests, "wall_ms_per_request": wall_seconds * 1000 / requests,
            "cpu_ms_per_request": cpu_seconds * 1000 / requests,
            "package_j_per_request": None if joules is None else joules / requests,
            "package_w": None if joules is None else joules / wall_seconds}


def summarize(samples):
    return {f"median_{key}": (None if samples[0][key] is None else
                              statistics.median(sample[key] for sample in samples))
            for key in samples[0] if key != "requests"}


def reduction(baseline, candidate):
    if baseline is None or candidate is None or baseline <= 0:
        return None
    return 100 * (1 - candidate / baseline)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prompts", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument("--width", type=int, default=128)
    parser.add_argument("--heads", type=int, default=4)
    parser.add_argument("--layers", type=int, default=2)
    parser.add_argument("--new-tokens", type=int, default=8)
    parser.add_argument("--rounds", type=int, default=8)
    parser.add_argument("--min-block-seconds", type=float, default=0.25)
    parser.add_argument("--seed", type=int, default=1567)
    parser.add_argument("--sudo-energy", action="store_true",
                        help="read package counters through a read-only sudo helper (terminal required)")
    parser.add_argument("--require-energy", action="store_true",
                        help="fail if energy cannot be measured")
    args = parser.parse_args()
    if min(args.threads, args.width, args.heads, args.layers, args.new_tokens,
           args.rounds) < 1 or not 0 < args.min_block_seconds <= 10:
        parser.error("counts must be positive and min-block-seconds must be in (0, 10]")
    if args.width % args.heads:
        parser.error("width must be divisible by heads")
    torch.set_num_threads(args.threads)
    torch.set_num_interop_threads(1)
    torch.manual_seed(args.seed)
    rows, groups, tensors, vocab = load_prompts(args.prompts)
    max_length = max(ids.shape[1] for items in tensors.values() for ids in items)
    if max_length + args.new_tokens > 4096:
        parser.error("this small CPU benchmark supports at most 4096 total tokens")
    model = TinyTransformer(vocab, max_length + args.new_tokens,
                            args.width, args.heads, args.layers).eval()
    energy = SudoPackageEnergy() if args.sudo_energy else PackageEnergy()
    if args.require_energy and not energy.status["available"]:
        energy.close()
        parser.error(f"energy measurement required: {energy.status['reason']}")
    print(f"CPU float32, {sum(p.numel() for p in model.parameters()):,} random parameters",
          flush=True)
    print(f"Energy: {energy.status}", flush=True)
    samples = {variant: [] for variant in VARIANTS}
    rng = random.Random(args.seed)
    with contextlib.closing(energy), torch.inference_mode():
        for prompts in tensors.values():
            for ids in prompts:
                model.generate(ids, args.new_tokens)
        for round_index in range(args.rounds):
            order = list(VARIANTS)
            rng.shuffle(order)
            for variant in order:
                samples[variant].append(measure(model, tensors[variant], args.new_tokens,
                                                energy, args.min_block_seconds))
            print(f"round {round_index + 1}/{args.rounds} complete", flush=True)
    results = {}
    for variant in VARIANTS:
        results[variant] = {
            "mean_input_tokens": statistics.mean(ids.shape[1] for ids in tensors[variant]),
            "target_recall": statistics.mean(row["target_recalled"] for row in groups[variant]),
            "mean_scanned": statistics.mean(row["scanned"] for row in groups[variant]),
            **summarize(samples[variant]), "samples": samples[variant]}
    report = {
        "schema_version": 1, "scope": "transformer_inference_only",
        "environment": {"python": platform.python_version(), "torch": torch.__version__,
                        "machine": platform.machine(), "threads": args.threads},
        "model": {"trained": False, "dtype": "float32", "device": "cpu",
                  "tokenizer": "corpus-local word/punctuation (not a production LLM tokenizer)",
                  "width": args.width, "heads": args.heads, "layers": args.layers,
                  "parameters": sum(p.numel() for p in model.parameters()),
                  "new_tokens": args.new_tokens, "kv_cache": True,
                  "batch_size": 1, "seed": args.seed},
        "measurement": {"rounds": args.rounds, "min_block_seconds": args.min_block_seconds,
                        "order": "seeded random per round", "energy": energy.status},
        "results": results,
        "wrong_ring_target_recall": (statistics.mean(row["target_recalled"] for row in rows
                                                     if row["variant"] == "wrong_ring")
                                     if any(row["variant"] == "wrong_ring" for row in rows)
                                     else None),
        "routed_vs_global_reduction_pct": {
            key: reduction(results["global"][key], results["routed"][key])
            for key in ("mean_input_tokens", "median_wall_ms_per_request",
                        "median_cpu_ms_per_request", "median_package_j_per_request")},
        "limitations": ["Untrained model: no answer-quality measurement.",
                        "Tokenizer counts are not production LLM token counts.",
                        "Inference only: excludes retrieval, routing, tokenization, training and import.",
                        "RAPL covers CPU packages, including background activity; not wall-plug energy.",
                        "No idle-baseline subtraction; compare repeated runs on a quiet host.",
                        "Shorter runtime alone does not establish energy savings."]}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print("variant              input_tokens  recall   wall_ms    cpu_ms    package_J    package_W")
    for variant, result in results.items():
        joules = result["median_package_j_per_request"]
        watts = result["median_package_w"]
        energy_text = "unavailable  unavailable" if joules is None else f"{joules:11.6f}  {watts:11.3f}"
        print(f"{variant:20} {result['mean_input_tokens']:12.1f}"
              f" {result['target_recall']:7.3f} {result['median_wall_ms_per_request']:9.3f}"
              f" {result['median_cpu_ms_per_request']:9.3f}  {energy_text}")
    print(f"JSON report: {args.output}")


if __name__ == "__main__":
    main()
