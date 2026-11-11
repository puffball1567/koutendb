"""Structured, trainable ring selection without enumerating all ring keys.

Product keys follow Large Memory Layers with Product Keys (Lample et al., 2019).
This module implements only ring routing, not that paper's complete architecture.
"""

import math

import torch
from torch import nn
from torch.nn import functional as F


def stable_topk(scores, identifiers, count):
    """Descending scores, then ascending IDs, including exact score ties."""
    by_id = identifiers.argsort(dim=-1, stable=True)
    ordered_scores = scores.gather(-1, by_id)
    ranked = ordered_scores.argsort(dim=-1, descending=True, stable=True)[..., :count]
    selected = by_id.gather(-1, ranked)
    return scores.gather(-1, selected), identifiers.gather(-1, selected)


class ProductRingRouter(nn.Module):
    """Exact top-k over a Cartesian family of learned representative keys.

    Each virtual key is concat(normalize(left[i]), normalize(right[j]))/sqrt(2).
    The full family is implicit. This changes the trainable key family, so an
    arbitrary flat router checkpoint cannot be converted losslessly.
    """

    def __init__(self, rings, key_dim, shape=None):
        super().__init__()
        if rings < 1 or key_dim < 2:
            raise ValueError("need positive rings and at least two key dimensions")
        if shape is None:
            rows = math.isqrt(rings)
            while rings % rows:
                rows -= 1
            shape = (rows, rings // rows)
        if len(shape) != 2 or min(shape) < 1 or shape[0] * shape[1] != rings:
            raise ValueError("factor dimensions must be positive and multiply to rings")
        self.rings, self.key_dim = rings, key_dim
        self.rows, self.columns = shape
        self.left_dim = key_dim // 2
        self.left = nn.Parameter(torch.randn(self.rows, self.left_dim))
        self.right = nn.Parameter(torch.randn(self.columns, key_dim - self.left_dim))
        self.register_buffer("eval_left", None, persistent=False)
        self.register_buffer("eval_right", None, persistent=False)

    def train(self, mode=True):
        super().train(mode)
        if mode:
            self.eval_left, self.eval_right = None, None
        else:
            with torch.no_grad():
                self.eval_left = F.normalize(self.left.detach(), dim=-1)
                self.eval_right = F.normalize(self.right.detach(), dim=-1)
        return self

    def factor_scores(self, queries):
        if queries.shape[-1] != self.key_dim:
            raise ValueError("query key dimension mismatch")
        left = F.normalize(self.left, dim=-1) if self.training else self.eval_left
        right = F.normalize(self.right, dim=-1) if self.training else self.eval_right
        return ((queries[..., :self.left_dim] @ left.T) / math.sqrt(2),
                (queries[..., self.left_dim:] @ right.T) / math.sqrt(2))

    def full_scores(self, queries):
        """Dense training surrogate/reference; not the sparse inference path."""
        left, right = self.factor_scores(queries)
        return (left.unsqueeze(-1) + right.unsqueeze(-2)).flatten(-2)

    def full_topk(self, queries, count):
        count = self._count(count)
        scores = self.full_scores(queries)
        ids = torch.arange(self.rings, device=queries.device).expand_as(scores)
        return stable_topk(scores, ids, count)

    def _count(self, count):
        if not isinstance(count, int) or count < 1:
            raise ValueError("top-k must be a positive integer")
        return min(count, self.rings)

    def topk(self, queries, count):
        """Score rows+columns representatives and at most k*k combinations."""
        count = self._count(count)
        left, right = self.factor_scores(queries)
        # Factor IDs are already in ascending order, so one stable score sort
        # also resolves ties. Only the small Cartesian candidate set needs both.
        ai = left.argsort(dim=-1, descending=True, stable=True)[..., :min(count, self.rows)]
        bi = right.argsort(dim=-1, descending=True, stable=True)[..., :min(count, self.columns)]
        a, b = left.gather(-1, ai), right.gather(-1, bi)
        scores = (a.unsqueeze(-1) + b.unsqueeze(-2)).flatten(-2)
        ids = (ai.unsqueeze(-1) * self.columns + bi.unsqueeze(-2)).flatten(-2)
        return stable_topk(scores, ids, count)

    def access_counts(self, queries, count):
        count = self._count(count)
        return {"router_keys_scored": queries * (self.rows + self.columns),
                "router_pair_candidates": queries * min(count, self.rows) * min(count, self.columns)}
