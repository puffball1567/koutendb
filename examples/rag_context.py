"""Deterministic, answer-independent context packing for the RAG recipe.

Merge overlapping chunks of the same source paragraph, then retain sentences
with query-term evidence. This heuristic is optional and must be quality-tested.
"""

import re


STOP = frozenset("a an the and or of to in on at for from with by is are was were be been being do does did what which who whom whose when where why how can could would should has have had it its this that these those as than then".split())


def terms(text):
    return {word for word in re.findall(r"[a-z0-9]+", text.lower()) if word not in STOP}


def join_overlap(left, right):
    if right in left:
        return left
    for size in range(min(len(left), len(right)), 11, -1):
        if left[-size:] == right[:size]:
            return left + right[size:]
    # Preserve an explicit separation when retrieved chunks have a gap.
    return left + "\n[…]\n" + right


class ContextPacker:
    def __init__(self, sentences=2):
        if sentences < 1:
            raise ValueError("sentence limit must be positive")
        self.sentences = sentences

    def compact_text(self, question, text):
        sentences = re.split(r"(?<=[.!?])\s+(?=[A-Z0-9\"“])", text.strip())
        query = terms(question)
        if len(sentences) <= self.sentences or not query:
            return text
        matched = terms(text) & query
        # A single generic/entity match cannot establish which sentence carries
        # the answer. Keep the full source when the query evidence is weak.
        if len(matched) < 2:
            return text
        windows = []
        for start in range(len(sentences) - self.sentences + 1):
            window = " ".join(sentences[start:start + self.sentences])
            evidence = terms(window) & query
            # Never discard query evidence spread across distant sentences.
            if evidence == matched:
                windows.append((len(window), start, window))
        if not windows:
            return text
        # Preserve a contiguous original passage and its local relationships.
        return min(windows)[2]

    def pack(self, question, hits):
        groups = {}
        seen = set()
        for index, hit in enumerate(hits):
            doc = hit["document"]
            identity = (doc.get("ring"), doc.get("id", str(index)))
            if identity in seen:
                continue
            seen.add(identity)
            source = (doc.get("ring"), doc.get("paragraph_id", identity))
            groups.setdefault(source, []).append(hit)
        result = []
        for group in groups.values():
            def offset(hit):
                suffix = hit["document"].get("id", "").rsplit(":", 1)[-1]
                return int(suffix) if suffix.isdigit() else 0
            ordered = sorted(group, key=offset)
            text = ordered[0]["document"]["text"]
            for hit in ordered[1:]:
                text = join_overlap(text, hit["document"]["text"])
            doc = dict(group[0]["document"])
            doc["text"] = self.compact_text(question, text)
            doc["source_chunk_ids"] = [hit["document"].get("id") for hit in ordered]
            result.append({"document": doc, "score": max(hit["score"] for hit in group)})
        return result
