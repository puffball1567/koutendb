"""A learned ring memory inside a small Transformer task model.

Values are latent float vectors, not answers. Routing sees only the hidden
state. Both dense and memory models use the same frozen token embeddings and
trainable attention stem. The final knowledge layer is interchangeable.
"""

import ctypes as C

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

from rag_energy_capi import Database, Id
from ring_memory_router import ProductRingRouter


def sparse_weights(scores, count, straight_through=False, soft=False):
    probabilities = scores.softmax(-1)
    if soft:
        return probabilities
    indices = scores.topk(min(count, scores.shape[-1]), dim=-1).indices
    selected = scores.gather(-1, indices).softmax(-1)
    hard = torch.zeros_like(scores).scatter(-1, indices, selected)
    return hard + probabilities - probabilities.detach() if straight_through else hard


class RingMemory(nn.Module):
    def __init__(self, width, key_dim=16, rings=16, slots=32, read_rings=2, read_slots=4,
                 allocate_tables=True, router_kind="flat"):
        super().__init__()
        self.width, self.key_dim = width, key_dim
        self.rings, self.slots = rings, slots
        self.read_rings, self.read_slots = min(read_rings, rings), min(read_slots, slots)
        self.query = nn.Linear(width, key_dim, bias=False)
        if router_kind not in ("flat", "product"):
            raise ValueError("router_kind must be flat or product")
        self.router_kind = router_kind
        self.ring_keys = nn.Parameter(torch.randn(rings, key_dim)) if router_kind == "flat" else None
        self.product_router = ProductRingRouter(rings, key_dim) if router_kind == "product" else None
        self.keys = nn.Parameter(torch.randn(rings, slots, key_dim)) if allocate_tables else None
        self.values = nn.Parameter(torch.randn(rings, slots, width) * .1) if allocate_tables else None
        self.output = nn.Linear(width, width)
        self.backend = "tensor_sparse"
        self.store = None
        self.soft_training = True
        self.last_stats = {}
        self.register_buffer("eval_keys", None, persistent=False)
        self.register_buffer("eval_ring_keys", None, persistent=False)

    def train(self, mode=True):
        super().train(mode)
        if mode:
            self.eval_keys, self.eval_ring_keys = None, None
        else:
            with torch.no_grad():
                self.eval_keys = None if self.keys is None else F.normalize(self.keys.detach(), dim=-1)
                self.eval_ring_keys = None if self.ring_keys is None else F.normalize(self.ring_keys.detach(), dim=-1)
        return self

    def forward(self, hidden):
        shape = hidden.shape
        q = F.normalize(self.query(hidden.reshape(-1, self.width)), dim=-1)
        if self.training:
            ring_scores = (self.product_router.full_scores(q) * 8 if self.product_router is not None else
                           q @ F.normalize(self.ring_keys, dim=-1).T * 8)
            local_scores = torch.einsum("bd,red->bre", q, F.normalize(self.keys, dim=-1)) * 8
            local_weights = sparse_weights(local_scores, self.read_slots, True, self.soft_training)
            ring_weights = sparse_weights(ring_scores, self.read_rings, True, self.soft_training)
            per_ring = torch.einsum("bre,rev->brv", local_weights, self.values)
            read = (per_ring * ring_weights.unsqueeze(-1)).sum(1)
        elif self.backend == "ablated":
            read = q.new_zeros((len(q), self.width))
        else:
            if self.product_router is not None:
                selected_scores, chosen = self.product_router.topk(q, self.read_rings)
                ring_weights = (selected_scores * 8).softmax(-1)
                routing_counts = self.product_router.access_counts(len(q), self.read_rings)
            else:
                ring_scores = q @ self.eval_ring_keys.T * 8
                chosen = ring_scores.topk(self.read_rings, dim=-1).indices
                ring_weights = ring_scores.gather(-1, chosen).softmax(-1)
                routing_counts = {"router_keys_scored": len(q) * self.rings}
            if self.backend == "koutendb":
                read, stats = self.store.read(q, chosen, ring_weights, self.read_slots)
                self.last_stats = stats
            else:
                if self.eval_keys is None or self.values is None:
                    raise ValueError("tensor backend requires resident memory tables")
                keys = self.eval_keys
                if self.backend == "tensor_full":
                    all_scores = torch.einsum("bd,red->bre", q, keys)
                    local_scores = all_scores.gather(1, chosen.unsqueeze(-1).expand(-1, -1, self.slots))
                    scored = len(q) * self.rings * self.slots
                elif self.backend == "tensor_sparse":
                    selected_keys = keys[chosen]
                    local_scores = torch.einsum("bd,bred->bre", q, selected_keys)
                    scored = len(q) * self.read_rings * self.slots
                else:
                    raise ValueError(f"unknown memory backend: {self.backend}")
                scores, indices = local_scores.topk(self.read_slots, dim=-1)
                values = self.values[chosen.unsqueeze(-1), indices]
                per_ring = ((scores * 8).softmax(-1).unsqueeze(-1) * values).sum(2)
                read = (per_ring * ring_weights.unsqueeze(-1)).sum(1)
                self.last_stats = {"queries": len(q), "scored_keys": scored,
                                   "read_value_vectors": len(q) * self.read_rings * self.read_slots}
            self.last_stats.update(routing_counts)
        return self.output(read).reshape(shape)


class TaskModel(nn.Module):
    def __init__(self, vocabulary, classes, width=64, rings=16, slots=32, entities=32, kind="ring", router_kind="flat"):
        super().__init__()
        self.kind, self.width = kind, width
        self.embedding = nn.Embedding(vocabulary, width, padding_idx=0)
        self.embedding.weight.requires_grad_(False)
        self.position = nn.Embedding(40, width)
        layer = nn.TransformerEncoderLayer(width, 4, 2 * width, dropout=0.,
                                            batch_first=True, norm_first=True)
        self.stem = nn.TransformerEncoder(layer, 2, enable_nested_tensor=False)
        self.entity_head = nn.Linear(width, entities)
        self.attribute_head = nn.Linear(width, 3)
        self.operation_head = nn.Linear(width, 2)
        # Fixed random semantic codes: no fact values or answer IDs are stored here.
        self.register_buffer("semantic_codes", torch.randn(entities + 3, width) / width ** .5)
        self.parser_frozen = False
        prototype = RingMemory(width, rings=rings, slots=slots, router_kind=router_kind)
        memory_parameters = sum(p.numel() for p in prototype.parameters())
        if kind == "ring":
            self.knowledge = prototype
        elif kind == "dense":
            intermediate = max(1, round((memory_parameters - width) / (2 * width + 1)))
            self.knowledge = nn.Sequential(nn.Linear(width, intermediate), nn.GELU(),
                                           nn.Linear(intermediate, width))
        else:
            raise ValueError(kind)
        self.classifier = nn.Sequential(nn.LayerNorm(4 * width + 2), nn.Linear(4 * width + 2, width),
                                         nn.GELU(), nn.Linear(width, classes))
        self.fact_decoder = nn.Linear(width, classes - 2)

    def parser_logits(self, ids):
        x = self.embedding(ids) + self.position(torch.arange(ids.shape[1]))
        hidden = self.stem(x, src_key_padding_mask=ids.eq(0))[:, :2]
        return self.entity_head(hidden), self.attribute_head(hidden), self.operation_head(hidden[:, 0])

    def freeze_parser(self):
        self.parser_frozen = True
        for name, parameter in self.named_parameters():
            if name.startswith(("embedding.", "position.", "stem.", "entity_head.", "attribute_head.", "operation_head.")):
                parameter.requires_grad_(False)

    def semantic_input(self, ids):
        if self.parser_frozen:
            with torch.no_grad():
                entity, attribute, operation = self.parser_logits(ids)
        else:
            entity, attribute, operation = self.parser_logits(ids)
        probabilities = torch.cat(((entity * 2).softmax(-1), (attribute * 2).softmax(-1)), -1)
        return probabilities @ self.semantic_codes, operation.softmax(-1)

    def forward(self, ids, return_facts=False):
        hidden, operation = self.semantic_input(ids)
        memory = self.knowledge(hidden)
        a, b = memory[:, 0], memory[:, 1]
        features = torch.cat((a, b, (a - b).abs(), a * b, operation), -1)
        logits = self.classifier(features)
        return (logits, self.fact_decoder(memory)) if return_facts else logits


class TensorMemoryStore(Database):
    """Persist learned keys and raw latent values in real KoutenDB rings."""

    def __init__(self, library, directory, memory, disk_backed=False, progress=None, aggregation="batched"):
        if aggregation not in ("batched", "per_ring"):
            raise ValueError("aggregation must be batched or per_ring")
        super().__init__(library, directory, disk_backed=disk_backed)
        self.aggregation = aggregation
        self.width = memory.width
        self.ring_count = memory.rings
        self.lib.kouten_put_vec_codec.argtypes = [C.c_void_p, C.c_char_p, C.c_void_p, C.c_size_t,
                                                  C.c_int, C.POINTER(C.c_float), C.c_size_t, C.POINTER(Id)]
        self.lib.kouten_put_vec_codec.restype = C.c_int
        keys = F.normalize(memory.keys.detach(), dim=-1).contiguous().numpy()
        values = memory.values.detach().contiguous().numpy()
        for ring in range(memory.rings):
            for slot in range(memory.slots):
                payload = values[ring, slot].tobytes()
                vector = (C.c_float * memory.key_dim)(*keys[ring, slot])
                identifier = Id()
                status = self.lib.kouten_put_vec_codec(
                    self.handle, self.name(ring), payload, len(payload), 0,
                    vector, memory.key_dim, C.byref(identifier))
                if status != 0:
                    self.fail()
                completed = ring * memory.slots + slot + 1
                if progress is not None and (completed % 1024 == 0 or completed == memory.rings * memory.slots):
                    progress(completed)

    @classmethod
    def open_snapshot(cls, library, directory, width, rings, disk_backed=False, aggregation="batched"):
        if aggregation not in ("batched", "per_ring"):
            raise ValueError("aggregation must be batched or per_ring")
        store = cls.__new__(cls)
        Database.__init__(store, library, directory, disk_backed=disk_backed)
        store.width, store.ring_count, store.aggregation = width, rings, aggregation
        return store

    @staticmethod
    def name(ring):
        return f"neural-memory/ring-{ring:04d}".encode()

    def read(self, queries, selected, gates, budget):
        if self.aggregation == "per_ring":
            return self.read_per_ring(queries, selected, gates, budget)
        if self.aggregation != "batched":
            raise ValueError("aggregation must be batched or per_ring")
        # Retrieval still uses the scoped C ABI. Aggregate all returned latent
        # vectors in two tensor reductions instead of constructing a tensor for
        # every value and dispatching softmax/reductions for every ring/query.
        shape = (len(queries), selected.shape[1], budget)
        values = np.zeros((*shape, self.width), dtype=np.float32)
        scores = np.full(shape, -np.inf, dtype=np.float32)
        scored, vectors, payload_bytes = 0, 0, 0
        for row, (query, rings) in enumerate(zip(queries.detach(), selected)):
            vector = (C.c_float * len(query))(*query.tolist())
            for column, ring in enumerate(rings.tolist()):
                pointer = self.lib.kouten_retrieve(self.handle, vector, len(query),
                                                    self.name(ring), budget, 0, 0)
                if not pointer:
                    self.fail()
                try:
                    result = pointer.contents
                    if not 0 < result.len <= budget:
                        raise ValueError("selected ring returned an invalid number of memory values")
                    scored += result.scanned
                    for i in range(result.len):
                        hit = result.hits[i]
                        if hit.payload_len != 4 * self.width:
                            raise ValueError("latent value size mismatch")
                        raw = C.string_at(hit.payload, hit.payload_len)
                        values[row, column, i] = np.frombuffer(raw, dtype=np.float32)
                        scores[row, column, i] = hit.score
                        vectors += 1
                        payload_bytes += len(raw)
                finally:
                    self.lib.kouten_retrieve_free(pointer)
        local_weights = (torch.from_numpy(scores) * 8).softmax(-1)
        per_ring = (torch.from_numpy(values) * local_weights.unsqueeze(-1)).sum(-2)
        read = (per_ring * gates.unsqueeze(-1)).sum(1)
        return read, {"queries": len(queries), "scored_keys": scored,
                      "read_value_vectors": vectors, "returned_value_bytes": payload_bytes}

    def read_per_ring(self, queries, selected, gates, budget):
        """Original aggregation path retained as a correctness/cost control."""
        rows, scored, vectors, payload_bytes = [], 0, 0, 0
        for query, rings, weights in zip(queries.detach(), selected, gates):
            vector = (C.c_float * len(query))(*query.tolist())
            per_ring = []
            for ring in rings.tolist():
                pointer = self.lib.kouten_retrieve(self.handle, vector, len(query),
                                                    self.name(ring), budget, 0, 0)
                if not pointer:
                    self.fail()
                try:
                    result = pointer.contents
                    scored += result.scanned
                    values, scores = [], []
                    for i in range(result.len):
                        hit = result.hits[i]
                        if hit.payload_len != 4 * self.width:
                            raise ValueError("latent value size mismatch")
                        raw = C.string_at(hit.payload, hit.payload_len)
                        values.append(torch.from_numpy(np.frombuffer(raw, dtype=np.float32).copy()))
                        scores.append(hit.score)
                        vectors += 1
                        payload_bytes += len(raw)
                    local_weights = (torch.tensor(scores) * 8).softmax(0)
                    per_ring.append((torch.stack(values) * local_weights[:, None]).sum(0))
                finally:
                    self.lib.kouten_retrieve_free(pointer)
            rows.append((torch.stack(per_ring) * weights[:, None]).sum(0))
        return torch.stack(rows), {"queries": len(queries), "scored_keys": scored,
                                   "read_value_vectors": vectors, "returned_value_bytes": payload_bytes}
