"""Minimal benchmark adapter for the repository's existing C ABI."""

import ctypes as C
import json


class Id(C.Structure):
    _fields_ = [("parent", C.c_uint64), ("epoch", C.c_uint32),
                ("seq", C.c_uint32), ("t_write", C.c_double)]


class Hit(C.Structure):
    _fields_ = [("id", Id), ("score", C.c_double), ("payload", C.c_void_p),
                ("payload_len", C.c_size_t)]


class Retrieval(C.Structure):
    _fields_ = [("len", C.c_size_t), ("hits", C.POINTER(Hit))] + [
        (name, C.c_int) for name in ("total_vectors", "scanned", "skipped_vectors",
                                    "returned", "rings_touched", "payload_bytes",
                                    "estimated_tokens", "fanout_nodes")] + [
        ("candidate_reduction", C.c_double)]


class Database:
    def __init__(self, library, directory, disk_backed=False):
        self.lib = C.CDLL(str(library.resolve()))
        self.lib.kouten_abi_version.restype = C.c_int
        if self.lib.kouten_abi_version() != 2:
            raise RuntimeError("benchmark adapter requires KoutenDB C ABI version 2")
        self.lib.kouten_last_error.restype = C.c_char_p
        self.lib.kouten_open_dir_options.argtypes = [C.c_int, C.c_char_p, C.c_int, C.c_int]
        self.lib.kouten_open_dir_options.restype = C.c_void_p
        self.lib.kouten_close.argtypes = [C.c_void_p]
        self.lib.kouten_close.restype = None
        self.lib.kouten_put_vec.argtypes = [C.c_void_p, C.c_char_p, C.c_void_p, C.c_size_t,
                                           C.POINTER(C.c_float), C.c_size_t, C.POINTER(Id)]
        self.lib.kouten_put_vec.restype = C.c_int
        self.lib.kouten_retrieve.argtypes = [C.c_void_p, C.POINTER(C.c_float), C.c_size_t,
                                            C.c_char_p, C.c_int, C.c_int, C.c_int]
        self.lib.kouten_retrieve.restype = C.POINTER(Retrieval)
        self.lib.kouten_retrieve_free.argtypes = [C.POINTER(Retrieval)]
        self.lib.kouten_retrieve_free.restype = None
        # Buffered persistent storage; retain the ordinary in-memory vector index.
        self.handle = self.lib.kouten_open_dir_options(1, str(directory).encode(), 0, int(disk_backed))
        if not self.handle:
            self.fail()

    def fail(self):
        raise RuntimeError((self.lib.kouten_last_error() or b"KoutenDB C ABI error").decode())

    def put(self, document, vector):
        payload = json.dumps(document).encode()
        values = (C.c_float * len(vector))(*vector)
        identifier = Id()
        if self.lib.kouten_put_vec(self.handle, document["ring"].encode(), payload,
                                   len(payload), values, len(vector), C.byref(identifier)) != 0:
            self.fail()

    def retrieve(self, vector, budget, ring=""):
        values = (C.c_float * len(vector))(*vector)
        result = self.lib.kouten_retrieve(self.handle, values, len(vector), ring.encode(),
                                          budget, 0, 0)
        if not result:
            self.fail()
        try:
            rr = result.contents
            hits = []
            for i in range(rr.len):
                hit = rr.hits[i]
                document = json.loads(C.string_at(hit.payload, hit.payload_len))
                hits.append({"document": document, "score": hit.score})
            return hits, rr.scanned
        finally:
            self.lib.kouten_retrieve_free(result)

    def close(self):
        if self.handle:
            self.lib.kouten_close(self.handle)
            self.handle = None
