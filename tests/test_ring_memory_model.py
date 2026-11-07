"""Internal-memory tests: learning gradients, held-out data and actual DB parity."""

import sys
import tempfile
import unittest
from pathlib import Path

import torch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "examples"))
from ring_memory_data import encode, make_task
from ring_memory_model import RingMemory, TaskModel, TensorMemoryStore


class MemoryChecks(unittest.TestCase):
    def setUp(self):
        torch.set_num_threads(1)
        torch.manual_seed(731)

    def test_memory_is_trainable_from_hidden_states_without_answer_or_ring_ids(self):
        memory = RingMemory(16, key_dim=8, rings=4, slots=8)
        hidden = torch.randn(3, 2, 16, requires_grad=True)
        output = memory(hidden)
        output.square().sum().backward()
        self.assertEqual(output.shape, hidden.shape)
        for tensor in (hidden, memory.query.weight, memory.ring_keys, memory.keys, memory.values):
            self.assertIsNotNone(tensor.grad)
            self.assertTrue(torch.isfinite(tensor.grad).all())
            self.assertGreater(float(tensor.grad.abs().sum()), 0)

    def test_sparse_and_full_tensor_backends_have_identical_outputs(self):
        memory = RingMemory(16, key_dim=8, rings=4, slots=8).eval()
        hidden = torch.randn(3, 2, 16)
        with torch.inference_mode():
            memory.backend = "tensor_full"
            full = memory(hidden)
            full_count = memory.last_stats["scored_keys"]
            memory.backend = "tensor_sparse"
            sparse = memory(hidden)
            sparse_count = memory.last_stats["scored_keys"]
        torch.testing.assert_close(full, sparse)
        self.assertEqual(full_count, 6 * 4 * 8)
        self.assertEqual(sparse_count, 6 * 2 * 8)

    def test_ablation_removes_dependence_on_memory_values(self):
        memory = RingMemory(16, key_dim=8, rings=4, slots=8).eval()
        memory.backend = "ablated"
        hidden = torch.randn(2, 2, 16)
        with torch.inference_mode():
            a = memory(hidden)
            memory.values.add_(100)
            b = memory(hidden)
        torch.testing.assert_close(a, b)

    @unittest.skipUnless((ROOT / "lib/libkoutendb.so").exists(), "build the C ABI first")
    def test_actual_database_stores_latent_tensors_and_matches_sparse_read(self):
        memory = RingMemory(16, key_dim=8, rings=4, slots=8).eval()
        hidden = torch.randn(2, 2, 16)
        with tempfile.TemporaryDirectory() as directory, torch.inference_mode():
            store = TensorMemoryStore(ROOT / "lib/libkoutendb.so", Path(directory), memory)
            try:
                expected = memory(hidden)
                memory.store, memory.backend = store, "koutendb"
                actual = memory(hidden)
                torch.testing.assert_close(actual, expected, atol=2e-6, rtol=2e-5)
                self.assertEqual(memory.last_stats["scored_keys"], 4 * 2 * 8)
                self.assertEqual(memory.last_stats["returned_value_bytes"], 4 * 2 * 4 * 16 * 4)
            finally:
                store.close()

    def test_capacity_matching_and_parser_freeze(self):
        torch.manual_seed(1)
        dense = TaskModel(100, 10, kind="dense")
        torch.manual_seed(1)
        ring = TaskModel(100, 10, kind="ring")
        a = sum(p.numel() for p in dense.knowledge.parameters())
        b = sum(p.numel() for p in ring.knowledge.parameters())
        self.assertLess(abs(a - b) / b, .005)
        ring.freeze_parser()
        self.assertFalse(any(p.requires_grad for p in ring.stem.parameters()))
        self.assertTrue(ring.knowledge.values.requires_grad)

    @unittest.skipUnless((ROOT / "lib/libkoutendb.so").exists(), "build the C ABI first")
    def test_disk_snapshot_reads_without_resident_key_value_tables(self):
        memory = RingMemory(16, key_dim=8, rings=4, slots=8).eval()
        hidden = torch.randn(2, 2, 16)
        with tempfile.TemporaryDirectory() as directory, torch.inference_mode():
            directory = Path(directory)
            expected = memory(hidden)
            store = TensorMemoryStore(ROOT / "lib/libkoutendb.so", directory, memory, disk_backed=True)
            store.close()
            routing = {k: v for k, v in memory.state_dict().items() if k not in ("keys", "values")}
            lightweight = RingMemory(16, key_dim=8, rings=4, slots=8, allocate_tables=False)
            lightweight.load_state_dict(routing)
            lightweight.eval()
            store = TensorMemoryStore.open_snapshot(ROOT / "lib/libkoutendb.so", directory, 16, 4, disk_backed=True)
            try:
                lightweight.store, lightweight.backend = store, "koutendb"
                self.assertIsNone(lightweight.keys)
                self.assertIsNone(lightweight.values)
                torch.testing.assert_close(lightweight(hidden), expected, atol=2e-6, rtol=2e-5)
            finally:
                store.close()


class DataChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.task = make_task()

    def test_knowledge_and_language_training_do_not_contain_test_questions(self):
        task = self.task
        test = {row["text"] for row in task["test"]}
        trained = {row["text"] for row in task["train_single"] + task["train_composition"]}
        parsed = {row["text"] for row in task["parser_training"]}
        self.assertFalse(test & trained)
        self.assertFalse(test & parsed)
        self.assertTrue(any("alias" in row["text"] for row in task["parser_training"]))

    def test_composition_pairs_are_disjoint_and_all_facts_are_learnable(self):
        task = self.task
        train = {tuple(sorted(map(tuple, row["facts"]))) for row in task["train_composition"]}
        validation = {tuple(sorted(map(tuple, row["facts"]))) for row in task["validation"] if row["kind"] == "composition"}
        held = {tuple(sorted(map(tuple, row["facts"]))) for row in task["test"] if row["kind"] == "composition"}
        self.assertFalse(train & held or train & validation or validation & held)
        known = {tuple(row["facts"][0]) for row in task["train_single"]}
        self.assertTrue(all(tuple(fact) in known for row in task["test"] for fact in row["facts"]))

    def test_encoder_accepts_questions_without_labels(self):
        ids, labels = encode([{"text": "what is the color of entity000"}], self.task["vocabulary"])
        self.assertEqual(labels.tolist(), [-1])
        self.assertEqual(ids[0, :2].tolist(), [1, 2])


if __name__ == "__main__":
    unittest.main()
