"""Accuracy experiment contracts, independent of its training outcomes."""

import sys
import unittest
from pathlib import Path

import torch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "examples"))
from ring_memory_data import make_task
from ring_memory_quality_bench import make_models, summarize


class QualityChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(1)
        cls.task = make_task(731, entities=128, pairs=4096, evaluation_pairs=512)

    def test_test_strings_and_unordered_pairs_are_held_out(self):
        task = self.task
        texts = {r["text"] for r in task["test"]}
        self.assertFalse(texts & {r["text"] for r in task["parser_training"]})
        self.assertFalse(texts & {r["text"] for r in task["train_single"] + task["train_composition"]})
        pairs = lambda rows: {tuple(sorted(map(tuple, r["facts"]))) for r in rows if r["kind"] == "composition"}
        train, validation, test = pairs(task["train_composition"]), pairs(task["validation"]), pairs(task["test"])
        self.assertFalse(train & validation or train & test or validation & test)
        self.assertEqual(sum(r["kind"] == "single" for r in task["test"]), 384)
        comparison = [r for r in task["test"] if r["kind"] == "composition"]
        self.assertEqual(len(comparison), 512)
        self.assertEqual(sum(r["label"] == 9 for r in comparison), 256)

    def test_layouts_match_capacity_and_share_all_common_initial_weights(self):
        models = make_models(self.task, 731)
        counts = {name: sum(p.numel() for p in model.knowledge.parameters()) for name, model in models.items()}
        self.assertLess((max(counts.values()) - min(counts.values())) / min(counts.values()), .005)
        shared = models["dense"].state_dict()
        for name in ("ring_coarse", "ring_fine"):
            model = models[name]
            self.assertEqual(model.knowledge.rings * model.knowledge.slots, 2048)
            for key, value in model.state_dict().items():
                if not key.startswith("knowledge."):
                    torch.testing.assert_close(value, shared[key])

    def test_parser_conditioned_accuracy_does_not_hide_errors_from_overall_score(self):
        row = {"kind": "single", "correct": True, "parser_correct": True, "both_facts_decoded_correctly": True}
        rows = [row, {**row, "correct": False, "parser_correct": False},
                {**row, "kind": "composition"}]
        result = summarize(rows)
        self.assertEqual(result["single"]["accuracy"], .5)
        self.assertEqual(result["single"]["accuracy_when_parser_correct"], 1.)
        self.assertEqual(result["single"]["total"], 2)


if __name__ == "__main__":
    unittest.main()
