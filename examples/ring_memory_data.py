"""Small synthetic relational language task; no facts or ring IDs enter the model API."""

import hashlib
import random
import re

import torch


ATTRIBUTES = ("color", "shape", "size")


def words(text):
    return re.findall(r"[a-z0-9]+|[:?]", text.lower())


def pair_partition(pair):
    return int.from_bytes(hashlib.sha256(repr(pair_identity(pair)).encode()).digest()[:4], "little") % 10


def pair_identity(pair):
    # Equality is symmetric: reversing the two facts must not cross splits.
    i, a, j, b = pair
    return tuple(sorted(((i, a), (j, b))))


def make_task(seed=731, entities=32, values=8, pairs=1024, evaluation_pairs=128):
    rng = random.Random(seed)
    world = [[rng.randrange(values) for _ in ATTRIBUTES] for _ in range(entities)]
    names = [f"entity{i:03d}" for i in range(entities)]
    single_templates = ["what is the {a} of {e}", "for {e} tell me the {a}",
                        "tell me what {a} {e} has", "what {a} has {e}",
                        "tell me the {a} of {e}"]
    pair_templates = ["is the {a} of {e} the same as the {b} of {f}",
                      "are {e} {a} and {f} {b} the same",
                      "for {e} {a} and {f} {b} tell me same or different",
                      "tell me : are the {a} of {e} and the {b} of {f} the same"]

    def single(i, a, template):
        return {"text": single_templates[template].format(a=ATTRIBUTES[a], e=names[i]),
                "label": world[i][a], "kind": "single", "facts": [(i, a)]}

    def pair_example(pair, template):
        i, a, j, b = pair
        text = pair_templates[template].format(e=names[i], f=names[j], a=ATTRIBUTES[a], b=ATTRIBUTES[b])
        return {"text": text, "label": values + int(world[i][a] == world[j][b]),
                "kind": "composition", "facts": [(i, a), (j, b)]}

    train_single = [single(i, a, t) for i in range(entities) for a in range(3) for t in range(3)]
    validation = [single(i, a, 3) for i in range(entities) for a in range(3)]
    test = [single(i, a, 4) for i in range(entities) for a in range(3)]
    sets, used = {}, set()
    for split, count, allowed in [("train", pairs, set(range(2, 10))),
                                  ("validation", evaluation_pairs, {0}), ("test", evaluation_pairs, {1})]:
        examples = []
        for same in (False, True):
            attempts = 0
            accepted = 0
            while accepted < count // 2:
                attempts += 1
                if attempts > 1_000_000:
                    raise ValueError("not enough distinct fact pairs for the requested task")
                pair = (rng.randrange(entities), rng.randrange(3), rng.randrange(entities), rng.randrange(3))
                i, a, j, b = pair
                if (i, a) == (j, b) or pair in used or pair_partition(pair) not in allowed:
                    continue
                if (world[i][a] == world[j][b]) != same:
                    continue
                used.add(pair)
                template = rng.randrange(2) if split == "train" else (2 if split == "validation" else 3)
                examples.append(pair_example(pair, template))
                accepted += 1
        sets[split] = examples
    validation += sets["validation"]
    test += sets["test"]
    # Teach the common parser the grammar on extra symbols, without ever
    # providing their fact values. Held-out knowledge questions stay unseen.
    parser_training = list(train_single) + list(sets["train"])
    aliases = [f"alias{i:03d}" for i in range(entities)]
    for i, alias in enumerate(aliases):
        for a, attribute in enumerate(ATTRIBUTES):
            for template in single_templates:
                parser_training.append({"text": template.format(a=attribute, e=alias),
                                        "kind": "single", "facts": [(entities + i, a)]})
    for _ in range(pairs * 2):
        i, j = rng.randrange(entities), rng.randrange(entities)
        a, b = rng.randrange(3), rng.randrange(3)
        template = rng.choice(pair_templates)
        parser_training.append({"text": template.format(e=aliases[i], f=aliases[j],
                                                        a=ATTRIBUTES[a], b=ATTRIBUTES[b]),
                                "kind": "composition", "facts": [(entities + i, a), (entities + j, b)]})
    all_rows = train_single + sets["train"] + validation + test + parser_training
    vocabulary = {"<pad>": 0, "<read0>": 1, "<read1>": 2}
    for word in sorted({word for row in all_rows for word in words(row["text"])}):
        vocabulary[word] = len(vocabulary)
    # The vocabulary reveals spellings, not fact values or held-out answers.
    return {"seed": seed, "entities": entities, "values": values, "world": world,
            "parser_entities": 2 * entities, "parser_training": parser_training,
            "vocabulary": vocabulary, "train_single": train_single,
            "train_composition": sets["train"], "validation": validation, "test": test}


def encode(rows, vocabulary):
    tokens = [[1, 2] + [vocabulary[word] for word in words(row["text"])] for row in rows]
    ids = torch.zeros((len(rows), max(map(len, tokens))), dtype=torch.long)
    for i, sequence in enumerate(tokens):
        ids[i, :len(sequence)] = torch.tensor(sequence)
    labels = torch.tensor([row.get("label", -1) for row in rows])
    return ids, labels
