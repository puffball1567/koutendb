"""Multi-prototype ring routing. Training uses document vectors only."""

import numpy as np


class PrototypeRouter:
    def __init__(self, documents, vectors, prototypes=8):
        if prototypes < 1:
            raise ValueError("prototype count must be positive")
        self.rings = sorted({doc["ring"] for doc in documents})
        centers, owners = [], []
        for owner, ring in enumerate(self.rings):
            points = vectors[[i for i, doc in enumerate(documents) if doc["ring"] == ring]]
            mean = points.mean(0)
            chosen = [int(np.argmax(points @ mean))]
            nearest = points @ points[chosen[0]]
            while len(chosen) < min(prototypes, len(points)):
                next_index = int(np.argmin(nearest))
                if next_index in chosen or nearest[next_index] >= .9999:
                    break
                chosen.append(next_index)
                nearest = np.maximum(nearest, points @ points[next_index])
            local = points[chosen].copy()
            for _ in range(4):
                labels = np.argmax(points @ local.T, axis=1)
                for i in range(len(local)):
                    cluster = points[labels == i]
                    if len(cluster):
                        centroid = cluster.mean(0)
                        local[i] = centroid / max(float(np.linalg.norm(centroid)), 1e-9)
            centers.extend(local)
            owners.extend([owner] * len(local))
        self.centers = np.asarray(centers, dtype=np.float32)
        self.owners = np.asarray(owners)

    def select(self, vector, count=4, ambiguity_gap=.015):
        scores = self.centers @ vector
        best = np.full(len(self.rings), -np.inf)
        np.maximum.at(best, self.owners, scores)
        order = np.argsort(-best, kind="stable")
        gap = float(best[order[0]] - best[order[1]]) if len(order) > 1 else 1.
        if not np.isfinite(best[order[0]]) or gap < ambiguity_gap:
            return [], gap
        return [self.rings[int(i)] for i in order[:count]], gap


def retrieve_rings(db, vector, budget, rings):
    if not rings:
        return db.retrieve(vector, budget)
    hits, scanned = {}, 0
    for ring in dict.fromkeys(rings):
        local, visits = db.retrieve(vector, budget, ring)
        scanned += visits
        for hit in local:
            identity = (hit["document"].get("ring"), hit["document"]["id"])
            if identity not in hits or hit["score"] > hits[identity]["score"]:
                hits[identity] = hit
    return sorted(hits.values(), key=lambda hit: (-hit["score"], hit["document"]["id"]))[:budget], scanned
