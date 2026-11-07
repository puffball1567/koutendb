#!/usr/bin/env python3
"""Download public, pinned model snapshots and SQuAD into an experiment folder."""

import argparse
import hashlib
import json
import os
from pathlib import Path


DATA_URL = "https://rajpurkar.github.io/SQuAD-explorer/dataset/dev-v1.1.json"
MODELS = {"generator": "google/flan-t5-small",
          "embedding": "sentence-transformers/all-MiniLM-L6-v2"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=Path(".tmp/rag-energy"))
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    os.environ["HF_HOME"] = str(work / "hf-cache")
    os.environ["HF_HUB_DISABLE_XET"] = "1"
    from huggingface_hub import HfApi, snapshot_download
    import requests

    manifest_file = work / "sources.json"
    previous = json.loads(manifest_file.read_text()) if manifest_file.exists() else {}
    dataset = work / "dev-v1.1.json"
    if not dataset.exists():
        print("Downloading SQuAD 1.1 development data", flush=True)
        response = requests.get(DATA_URL, timeout=90)
        response.raise_for_status()
        # Validate before making the download available to the runner.
        json.loads(response.content)
        dataset.write_bytes(response.content)
    digest = hashlib.sha256(dataset.read_bytes()).hexdigest()
    if previous and previous["dataset"]["sha256"] != digest:
        raise ValueError("dataset differs from the recorded SHA-256")
    manifest = {"dataset": {"url": DATA_URL, "sha256": digest,
                             "license": "CC BY-SA 4.0", "file": dataset.name}, "models": {}}
    api = HfApi(token=False)
    for role, repo in MODELS.items():
        old = previous.get("models", {}).get(role, {})
        revision = old.get("revision") or api.model_info(repo).sha
        destination = work / "models" / role
        print(f"Downloading {repo} at {revision}", flush=True)
        snapshot_download(repo, revision=revision, local_dir=destination,
                          cache_dir=work / "hf-cache", token=False,
                          allow_patterns=["config.json", "generation_config.json", "model.safetensors",
                                          "tokenizer.json", "tokenizer_config.json", "vocab.txt",
                                          "special_tokens_map.json", "spiece.model", "README.md",
                                          "sentence_bert_config.json"])
        if not (destination / "model.safetensors").exists():
            raise ValueError(f"{repo} did not provide the expected safetensors weights")
        manifest["models"][role] = {"repo": repo, "revision": revision,
                                     "directory": f"models/{role}", "license": "Apache-2.0"}
    manifest_file.write_text(json.dumps(manifest, indent=2) + "\n")
    print("Public model snapshots and dataset are ready.", flush=True)


if __name__ == "__main__":
    main()
