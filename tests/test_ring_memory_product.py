"""Product routing must select the same virtual keys without enumerating them."""

import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import torch
from torch.nn import functional as F

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "examples"))
from ring_memory_router import ProductRingRouter
from ring_memory_model import RingMemory, TensorMemoryStore
from ring_memory_product_bench import build_models


class ProductChecks(unittest.TestCase):
    def setUp(self):
        torch.set_num_threads(1)
        torch.manual_seed(1567)

    def test_topk_matches_all_virtual_keys_including_rectangular_and_prime_shapes(self):
        for rings in (1, 16, 17, 32, 1024):
            router = ProductRingRouter(rings, 16).eval()
            queries = F.normalize(torch.randn(3, 2, 16), dim=-1)
            with torch.inference_mode():
                for count in (1, 2, 5, rings + 1):
                    actual = router.topk(queries, count)
                    expected = router.full_topk(queries, count)
                    torch.testing.assert_close(actual[0], expected[0], rtol=0, atol=0)
                    self.assertTrue(torch.equal(actual[1], expected[1]))

    def test_tied_scores_choose_lowest_ring_ids_deterministically(self):
        router = ProductRingRouter(64, 16).eval()
        query = torch.zeros(2, 16)
        with torch.inference_mode():
            scores, ids = router.topk(query, 5)
        self.assertEqual(ids.tolist(), [list(range(5))] * 2)
        self.assertEqual(scores.tolist(), [[0.] * 5] * 2)

    def test_fast_path_does_not_call_dense_score_expansion(self):
        router = ProductRingRouter(65536, 16).eval()
        with patch.object(router, "full_scores", side_effect=AssertionError("dense expansion")), torch.inference_mode():
            scores, ids = router.topk(F.normalize(torch.randn(2, 16), dim=-1), 2)
        self.assertEqual(scores.shape, (2, 2))
        self.assertTrue(bool((ids < 65536).all()))
        self.assertEqual(router.access_counts(2, 2), {"router_keys_scored": 1024, "router_pair_candidates": 8})

    def test_factor_scores_equal_cosine_scores_of_explicit_cartesian_keys(self):
        router = ProductRingRouter(32, 16).eval()
        with torch.inference_mode():
            keys = torch.cat((router.eval_left[:, None, :].expand(-1, router.columns, -1),
                              router.eval_right[None, :, :].expand(router.rows, -1, -1)), -1).flatten(0, 1) / 2**.5
            query = F.normalize(torch.randn(4, 16), dim=-1)
            torch.testing.assert_close(router.full_scores(query), query @ keys.T, atol=2e-7, rtol=2e-6)

    def test_router_is_trainable_from_hidden_queries(self):
        router = ProductRingRouter(64, 16)
        query = torch.randn(3, 16, requires_grad=True)
        logits = router.full_scores(query)
        loss = F.cross_entropy(logits, torch.tensor([1, 20, 40]))
        loss.backward()
        for tensor in (query, router.left, router.right):
            self.assertIsNotNone(tensor.grad)
            self.assertTrue(torch.isfinite(tensor.grad).all())
            self.assertGreater(float(tensor.grad.abs().sum()), 0)

    def test_memory_full_and_sparse_paths_agree_with_product_routing(self):
        memory = RingMemory(16, key_dim=8, rings=16, slots=8, router_kind="product").eval()
        hidden = torch.randn(3, 2, 16)
        with torch.inference_mode():
            sparse = memory(hidden)
            self.assertEqual(memory.last_stats["router_keys_scored"], 6 * 8)
            memory.backend = "tensor_full"
            torch.testing.assert_close(memory(hidden), sparse)
            with patch.object(memory.product_router, "topk", wraps=memory.product_router.full_topk):
                torch.testing.assert_close(memory(hidden), sparse)

    @unittest.skipUnless((ROOT / "lib/libkoutendb.so").exists(), "build the C ABI first")
    def test_product_routing_reads_the_same_latent_values_from_actual_db(self):
        memory = RingMemory(16, key_dim=8, rings=16, slots=8, router_kind="product").eval()
        hidden = torch.randn(2, 2, 16)
        work = ROOT / ".tmp"
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="product-contract-", dir=work) as directory, torch.inference_mode():
            expected = memory(hidden)
            store = TensorMemoryStore(ROOT / "lib/libkoutendb.so", Path(directory), memory)
            try:
                memory.store, memory.backend = store, "koutendb"
                torch.testing.assert_close(memory(hidden), expected, atol=2e-6, rtol=2e-5)
                self.assertEqual(memory.last_stats["router_keys_scored"], 4 * 8)
                self.assertEqual(memory.last_stats["scored_keys"], 4 * 2 * 8)
                batched_stats = dict(memory.last_stats)
                store.aggregation = "per_ring"
                torch.testing.assert_close(memory(hidden), expected, atol=2e-6, rtol=2e-5)
                self.assertEqual(memory.last_stats, batched_stats)
                # A larger read budget pads short rings. Masking must preserve
                # their original softmax and never introduce NaN or fake hits.
                queries = F.normalize(memory.query(hidden.flatten(0, 1)), dim=-1)
                scores, selected = memory.product_router.topk(queries, 2)
                gates = (scores * 8).softmax(-1)
                reference, reference_stats = store.read(queries, selected, gates, 10)
                store.aggregation = "batched"
                actual, actual_stats = store.read(queries, selected, gates, 10)
                torch.testing.assert_close(actual, reference, atol=2e-6, rtol=2e-5)
                self.assertEqual(actual_stats, reference_stats)
                self.assertEqual(actual_stats["read_value_vectors"], 4 * 2 * 8)
            finally:
                store.close()
        Path(directory + ".kouten-dir.lock").unlink(missing_ok=True)

    def test_invalid_shapes_queries_and_budgets_are_rejected(self):
        for kwargs in ({"rings": 0, "key_dim": 16}, {"rings": 4, "key_dim": 1},
                       {"rings": 16, "key_dim": 16, "shape": (3, 5)}):
            with self.assertRaises(ValueError):
                ProductRingRouter(**kwargs)
        router = ProductRingRouter(16, 16)
        with self.assertRaises(ValueError):
            router.topk(torch.randn(2, 8), 2)
        with self.assertRaises(ValueError):
            router.topk(torch.randn(2, 16), 0)

    def test_comparison_starts_with_identical_shared_and_local_memory_weights(self):
        models = build_models({"width": 64, "rings": 16, "slots": 8, "entities": 32}, 40, 10, 731)
        flat = models["flat"].state_dict()
        for key, value in models["product"].state_dict().items():
            if not key.startswith("knowledge.product_router."):
                torch.testing.assert_close(value, flat[key], atol=0, rtol=0)

    @unittest.skipUnless((ROOT / "lib/libkoutendb.so").exists(), "build the C ABI first")
    def test_disk_snapshot_can_use_product_routing_without_resident_local_tables(self):
        memory = RingMemory(16, key_dim=8, rings=16, slots=8, router_kind="product").eval()
        hidden = torch.randn(2, 2, 16)
        work = ROOT / ".tmp"
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="product-disk-contract-", dir=work) as directory, torch.inference_mode():
            expected = memory(hidden)
            store = TensorMemoryStore(ROOT / "lib/libkoutendb.so", Path(directory), memory, disk_backed=True)
            store.close()
            lightweight = RingMemory(16, key_dim=8, rings=16, slots=8, allocate_tables=False, router_kind="product")
            lightweight.load_state_dict({k: v for k, v in memory.state_dict().items() if k not in ("keys", "values")})
            lightweight.eval()
            store = TensorMemoryStore.open_snapshot(ROOT / "lib/libkoutendb.so", Path(directory), 16, 16, disk_backed=True)
            try:
                lightweight.backend, lightweight.store = "koutendb", store
                self.assertIsNone(lightweight.keys)
                self.assertIsNone(lightweight.values)
                torch.testing.assert_close(lightweight(hidden), expected, atol=2e-6, rtol=2e-5)
            finally:
                store.close()
        Path(directory + ".kouten-dir.lock").unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
