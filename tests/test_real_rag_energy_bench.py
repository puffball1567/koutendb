"""Independent checks of QA scoring, selection, routing and paired analysis."""

import importlib.util
import sys
import unittest
from pathlib import Path

import numpy as np


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "examples"))
SPEC = importlib.util.spec_from_file_location(
    "real_rag", Path(__file__).resolve().parents[1] / "examples/real_rag_energy_bench.py")
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)
from rag_context import ContextPacker
from rag_routing import PrototypeRouter, retrieve_rings


class FakeTokenizer:
    def __call__(self, text, **kwargs):
        if kwargs.get("return_offsets_mapping"):
            return {"offset_mapping": [(i, i + 1) for i in range(len(text))]}
        import torch
        return {"input_ids": torch.zeros((1, len(text)), dtype=torch.long)}

    def encode(self, text, **kwargs):
        return list(range(len(text)))


class QualityChecks(unittest.TestCase):
    def test_overlapping_context_merges_within_source_and_ring(self):
        docs = [{"id": "p:0", "paragraph_id": "p", "ring": "a", "title": "topic",
                 "text": "Prefix. shared overlapping evidence"},
                {"id": "p:80", "paragraph_id": "p", "ring": "a", "title": "topic",
                 "text": "shared overlapping evidence ends here."},
                {"id": "p:0", "paragraph_id": "p", "ring": "b", "title": "other",
                 "text": "Another tenant's text."}]
        packed = ContextPacker().pack("", [{"document": doc, "score": .8} for doc in docs])
        self.assertEqual(len(packed), 2)
        self.assertEqual(packed[0]["document"]["text"], "Prefix. shared overlapping evidence ends here.")
        self.assertEqual(packed[1]["document"]["ring"], "b")
        self.assertEqual(len(packed[0]["document"]["source_chunk_ids"]), 2)

    def test_context_selection_uses_query_and_retains_original_sentences(self):
        text = "Lunch is served. Refund requests take three days. Accounts need an invoice. The garden is green."
        packer = ContextPacker(sentences=2)
        compact = packer.compact_text("How long do refund requests take?", text)
        self.assertIn("Refund requests take three days.", compact)
        self.assertLess(len(compact), len(text))
        self.assertEqual(packer.compact_text("unmatchedword", text), text)

    def test_weak_or_distributed_query_evidence_keeps_full_context(self):
        text = "Kenya has several cities. Nairobi is its capital. Coastal tourism serves Kenya."
        packer = ContextPacker(sentences=1)
        self.assertEqual(packer.compact_text("What is the capitol of Kenya?", text), text)
        self.assertEqual(packer.compact_text("How does Nairobi relate to tourism?", text), text)

    def test_multiple_prototypes_cover_opposing_topics_without_answer_labels(self):
        documents = [{"ring": "mixed"}, {"ring": "mixed"}, {"ring": "other"}]
        vectors = np.array([[1., 0.], [-1., 0.], [0., 1.]], dtype=np.float32)
        router = PrototypeRouter(documents, vectors, prototypes=2)
        self.assertEqual(router.select(np.array([1., 0.]), 1)[0], ["mixed"])
        self.assertEqual(router.select(np.array([-1., 0.]), 1)[0], ["mixed"])
        self.assertEqual(router.select(np.array([0., 0.]), 1)[0], [])

    def test_multi_ring_retrieval_merges_scores_and_counts_every_visit(self):
        class FakeDb:
            def retrieve(self, vector, budget, ring):
                return [{"document": {"id": ring}, "score": {"a": .5, "b": .9}[ring]}], 10
        hits, scanned = retrieve_rings(FakeDb(), None, 1, ["a", "b", "a"])
        self.assertEqual(scanned, 20)
        self.assertEqual(hits[0]["document"]["id"], "b")

    def test_standard_normalization_and_best_gold_answer(self):
        self.assertEqual(bench.score_answer("The Eiffel Tower!", ["Eiffel Tower", "Paris"]), (1.0, 1.0))
        em, f1 = bench.score_answer("red red car", ["red car"])
        self.assertEqual(em, 0)
        self.assertAlmostEqual(f1, 0.8)
        self.assertEqual(bench.score_answer("unrelated", ["correct answer"]), (0, 0))

    def test_router_uses_similarity_and_falls_back_on_ambiguity(self):
        centers = np.eye(2)
        self.assertEqual(bench.select_ring(np.array([1., 0.]), ["a", "b"], centers, .1)[0], "a")
        self.assertEqual(bench.select_ring(np.array([.5, .5]), ["a", "b"], centers, .1)[0], "")

    def test_sampling_does_not_use_answer_content(self):
        data = {"data": [{"title": "topic", "paragraphs": [
            {"context": "abcdefghij", "qas": [{"id": "q", "question": "question?",
                                                "answers": [{"text": "SECRET"}]}]}]}]}
        docs, questions = bench.build_corpus(data, FakeTokenizer(), 4, 1, 1)
        self.assertEqual([doc["text"] for doc in docs], ["abcd", "defg", "ghij"])
        self.assertTrue(all("SECRET" not in str(doc) for doc in docs))
        self.assertEqual(len(questions), 1)
        self.assertEqual(questions[0]["answers"], ["SECRET"])

    def test_prompt_budget_drops_whole_documents_without_using_answers(self):
        tokenizer = FakeTokenizer()
        q = "Q?"
        hit = {"document": {"title": "topic", "text": "evidence"}}
        one, _ = bench.pack_prompt(q, [hit], tokenizer, 1000)
        encoded, docs = bench.pack_prompt(q, [hit, hit], tokenizer, one["input_ids"].shape[1])
        self.assertEqual(len(docs), 1)
        self.assertEqual(encoded["input_ids"].shape[1], one["input_ids"].shape[1])

    def test_paired_quality_and_energy_gate(self):
        baseline = {str(i): {"f1": .8, "package_j": 2.0} for i in range(12)}
        candidate = {str(i): {"f1": .8, "package_j": 1.0} for i in range(12)}
        result = bench.bootstrap_comparison(baseline, candidate, .05, 1)
        self.assertEqual(result["energy_reduction_pct"], 50)
        self.assertTrue(result["quality_preserving_energy_savings_demonstrated"])
        candidate = {str(i): {"f1": .5, "package_j": 1.0} for i in range(12)}
        result = bench.bootstrap_comparison(baseline, candidate, .05, 1)
        self.assertFalse(result["quality_preserving_energy_savings_demonstrated"])

    def test_missing_energy_cannot_pass_savings_gate(self):
        values = {str(i): {"f1": 1., "package_j": None} for i in range(4)}
        result = bench.bootstrap_comparison(values, values, .05, 1)
        self.assertIsNone(result["energy_reduction_pct"])
        self.assertFalse(result["quality_preserving_energy_savings_demonstrated"])


if __name__ == "__main__":
    unittest.main()
