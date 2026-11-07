"""Correctness checks for the optional Transformer measurement harness."""

import importlib.util
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

import torch


SPEC = importlib.util.spec_from_file_location(
    "energy_bench", Path(__file__).resolve().parents[1] / "examples/transformer_energy_bench.py")
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)
READER_SPEC = importlib.util.spec_from_file_location(
    "rapl_reader", Path(__file__).resolve().parents[1] / "examples/rapl_energy_reader.py")
reader = importlib.util.module_from_spec(READER_SPEC)
READER_SPEC.loader.exec_module(reader)


class TransformerChecks(unittest.TestCase):
    def setUp(self):
        torch.set_num_threads(1)
        torch.manual_seed(1)
        self.model = bench.TinyTransformer(24, 32, width=16, heads=2, layers=2).eval()

    def test_cached_logits_match_full_causal_sequence(self):
        # Test multiple decode positions to catch offset/mask/cache errors.
        ids = torch.tensor([[1, 2, 3, 4, 5, 6]])
        with torch.inference_mode():
            _, cache = self.model(ids[:, :3])
            for position in range(3, ids.shape[1]):
                cached, cache = self.model(ids[:, position:position + 1], cache)
                full, _ = self.model(ids[:, :position + 1])
                torch.testing.assert_close(cached, full, atol=1e-6, rtol=1e-5)

    def test_prefill_cache_does_not_include_future_information(self):
        with torch.inference_mode():
            _, short = self.model(torch.tensor([[1, 2, 3]]))
            _, long = self.model(torch.tensor([[1, 2, 3, 8, 9]]))
            for short_layer, long_layer in zip(short, long):
                for a, b in zip(short_layer, long_layer):
                    torch.testing.assert_close(a, b[:, :, :3], atol=1e-6, rtol=1e-5)

    def test_fixed_output_length(self):
        with torch.inference_mode():
            ids = torch.tensor([[1, 2]])
            expected, _ = self.model(ids)
            self.assertTrue(torch.equal(self.model.generate(ids, 1),
                                        expected.argmax(-1, keepdim=True)))
            for _ in range(4):
                expected, _ = self.model(ids)
                ids = torch.cat((ids, expected.argmax(-1, keepdim=True)), dim=1)
            self.assertTrue(torch.equal(self.model.generate(torch.tensor([[1, 2]]), 4),
                                        ids[:, -1:]))


class MeasurementChecks(unittest.TestCase):
    def write_zone(self, root, name, label, value=10, maximum=100):
        zone = root / name
        zone.mkdir()
        (zone / "name").write_text(label)
        (zone / "energy_uj").write_text(str(value))
        (zone / "max_energy_range_uj").write_text(str(maximum))

    def test_package_energy_wrap_and_no_subdomain_double_count(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            self.write_zone(root, "intel-rapl:0", "package-0")
            self.write_zone(root, "intel-rapl:0:0", "core")
            (root / "alias").symlink_to(root / "intel-rapl:0", target_is_directory=True)
            meter = bench.PackageEnergy(root)
            self.assertEqual(len(meter.zones), 1)
            self.assertAlmostEqual(meter.joules([90], [10]), 20 / 1_000_000)

    def test_no_energy_is_null_not_zero(self):
        with tempfile.TemporaryDirectory() as work:
            meter = bench.PackageEnergy(Path(work))
            self.assertFalse(meter.status["available"])
            self.assertIsNone(meter.joules([], []))

    def test_invalid_package_disables_partial_coverage(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            self.write_zone(root, "intel-rapl:0", "package-0")
            self.write_zone(root, "intel-rapl:1", "package-1", maximum=0)
            meter = bench.PackageEnergy(root)
            self.assertFalse(meter.status["available"])
            self.assertIsNone(meter.joules([], []))

    def test_unpaired_queries_rejected(self):
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / "prompts.jsonl"
            path.write_text("\n".join(json.dumps({"variant": variant, "query": str(i),
                                                 "prompt": "reference text",
                                                 "target_recalled": True})
                                      for i, variant in enumerate(bench.VARIANTS)))
            with self.assertRaisesRegex(ValueError, "identical query sets"):
                bench.load_prompts(path)

    def test_privileged_reader_protocol_is_read_only(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            self.write_zone(root, "intel-rapl:0", "package-0", value=25)
            self.write_zone(root, "intel-rapl:0:0", "core", value=10)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                reader.serve(reader.discover(root), io.StringIO("read\nread\n"))
            messages = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(messages, [{"domains": ["intel-rapl:0"], "ranges": [100]},
                                        {"values": [25]}, {"values": [25]}])
            self.assertEqual((root / "intel-rapl:0" / "energy_uj").read_text(), "25")

    def test_privileged_reader_rejects_other_commands(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            self.write_zone(root, "intel-rapl:0", "package-0")
            with contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(ValueError, "only the read command"):
                    reader.serve(reader.discover(root), io.StringIO("write 0\n"))
            self.assertEqual((root / "intel-rapl:0" / "energy_uj").read_text(), "10")


if __name__ == "__main__":
    unittest.main()
