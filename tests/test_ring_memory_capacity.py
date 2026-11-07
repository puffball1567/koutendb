"""Capacity probe contracts: fair size, resource bound and failure cleanup."""

import argparse
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import torch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "examples"))
import ring_memory_capacity_bench as probe
from ring_memory_model import RingMemory


class CapacityChecks(unittest.TestCase):
    def test_logical_capacity_matches_actual_parameters_and_dense_control(self):
        for rings in (2, 16, 64):
            memory = RingMemory(64, rings=rings)
            actual = sum(p.numel() for p in memory.parameters())
            self.assertEqual(probe.memory_parameters(64, rings, 32), actual)
            dense = probe.dense_layer(64, actual)
            count = sum(p.numel() for p in dense.parameters())
            self.assertLessEqual(abs(actual - count), 65)

    def test_budget_has_headroom_without_allocating_large_files(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            (directory / "data").write_bytes(b"x" * 100)
            self.assertEqual(probe.check_budget(directory, 32 * 1024**2 + 100), 100)
            with self.assertRaises(RuntimeError):
                probe.check_budget(directory, 32 * 1024**2 + 99)

    def test_failure_removes_own_snapshot_and_preserves_other_files(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            (directory / "keep.json").write_text("{}")
            args = argparse.Namespace(width=64, ring_counts=[16], include_wide_ring=False, work=directory)

            def fail(*args):
                (args[1] / "generated-data").write_bytes(b"temporary")
                raise RuntimeError("simulated preparation failure")

            with patch.object(probe, "run_worker", side_effect=fail), self.assertRaises(RuntimeError):
                probe.orchestrate(args)
            self.assertEqual([p.name for p in directory.iterdir()], ["keep.json"])

    def test_latent_workload_is_reproducible_and_not_one_repeated_query(self):
        args = argparse.Namespace(seed=731, questions=64, width=64)
        hidden = probe.inputs(args)
        torch.testing.assert_close(hidden, probe.inputs(args))
        self.assertEqual(hidden.shape, (64, 2, 64))
        self.assertEqual(len(torch.unique(hidden.flatten(1), dim=0)), 64)

    def test_mapped_dense_weights_produce_the_same_forward_result(self):
        dense = probe.dense_layer(64, probe.memory_parameters(64, 16, 32))
        hidden = torch.randn(1, 2, 64)
        with tempfile.TemporaryDirectory() as directory, torch.inference_mode():
            path = Path(directory) / "dense.pt"
            torch.save(dense.state_dict(), path)
            mapped = probe.dense_layer(64, probe.memory_parameters(64, 16, 32), device="meta")
            mapped.load_state_dict(torch.load(path, weights_only=True, mmap=True), assign=True)
            torch.testing.assert_close(mapped(hidden), dense(hidden))


if __name__ == "__main__":
    unittest.main()
