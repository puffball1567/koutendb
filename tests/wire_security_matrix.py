"""Bounded loopback regressions; no production endpoints or credentials."""
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

CLIENT, SERVER = sys.argv[1:3]
sys.argv = sys.argv[:1]


def line(sock):
    result = bytearray()
    while not result.endswith(b"\n"):
        part = sock.recv(1)
        if not part:
            raise EOFError("peer disconnected")
        result.extend(part)
        if len(result) > 65536:
            raise ValueError("test header too large")
    return bytes(result).strip().split()


def exact(sock, size):
    result = bytearray()
    while len(result) < size:
        part = sock.recv(size - len(result))
        if not part:
            raise EOFError("truncated body")
        result.extend(part)
    return bytes(result)


class WireSecurity(unittest.TestCase):
    def fake_peer(self, mode, handler):
        errors, calls = [], []
        stop = threading.Event()
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            listener.settimeout(0.1)
            endpoint = "127.0.0.1:" + str(listener.getsockname()[1])

            def serve():
                while not stop.is_set():
                    try:
                        conn, _ = listener.accept()
                    except socket.timeout:
                        continue
                    try:
                        with conn:
                            conn.settimeout(3)
                            request = line(conn)
                            calls.append(request)
                            handler(conn, request, len(calls))
                    except Exception as error:
                        errors.append(error)

            thread = threading.Thread(target=serve)
            thread.start()
            try:
                result = subprocess.run([CLIENT, mode, endpoint], timeout=15,
                                        capture_output=True, text=True)
            finally:
                stop.set()
                thread.join(timeout=5)
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return calls

    def test_lost_write_ack_is_not_replayed(self):
        def handle(conn, request, count):
            self.assertEqual(request[0], b"PUTR")
            exact(conn, int(request[1]) + int(request[2]))
            if count > 1:
                conn.sendall(b"ID 1 1 2 1 60 0\n")
        self.assertEqual(len(self.fake_peer("write", handle)), 1)

    def test_read_retries_once(self):
        def handle(conn, request, count):
            self.assertEqual(request, [b"HEALTH"])
            if count == 2:
                conn.sendall(b"OK healthy\n")
        self.assertEqual(len(self.fake_peer("read", handle)), 2)

    def test_repeated_read_failure_stops_after_two_attempts(self):
        def handle(conn, request, count):
            self.assertEqual(request, [b"HEALTH"])
        self.assertEqual(len(self.fake_peer("read-fail", handle)), 2)

    def test_fenced_idempotent_control_retries_once(self):
        def handle(conn, request, count):
            self.assertEqual(request, [b"COORDRESUME", b"7"])
            if count == 2:
                conn.sendall(b"OK active\n")
        self.assertEqual(len(self.fake_peer("idempotent-control", handle)), 2)

    def test_invalid_response_discards_connection(self):
        responses = {
            "bad-list": b"LVAL 2 _\nITEM 0 1 1 1 raw\nxITEM 1 1 1 67108864 raw\n",
            "bad-rings": b"RINGS 2\nRING 1 1 1\n" + struct.pack("<f", 1) +
                         b"RING 2 1 16777216\n",
            "bad-retrieve": b"RHIT 2 1 2 2 67108865\n",
            "bad-batch": b"BVAL 1 6\n9\noops",
        }
        for mode, response in responses.items():
            with self.subTest(mode=mode):
                def handle(conn, request, count):
                    if count == 1:
                        if mode in ("bad-list", "bad-retrieve"):
                            self.assertEqual(request, [b"CODECMETA", b"ON"])
                            conn.sendall(b"OK\n")
                            request = line(conn)
                        if mode == "bad-retrieve":
                            exact(conn, 4)
                        if mode == "bad-batch":
                            exact(conn, int(request[2]))
                        conn.sendall(response)
                        self.assertEqual(conn.recv(1), b"")
                    else:
                        self.assertEqual(request, [b"HEALTH"])
                        conn.sendall(b"OK healthy\n")
                self.assertEqual(len(self.fake_peer(mode, handle)), 2)

    def test_codec_negotiation_survives_retry_and_explicit_close(self):
        def handle(conn, request, count):
            self.assertEqual(request, [b"CODECMETA", b"ON"])
            conn.sendall(b"OK\n")
            self.assertEqual(line(conn)[0], b"LISTR")
            if count > 1:
                conn.sendall(b"LVAL 1 _\nITEM 0 1 1 1 bif\nx")
        self.assertEqual(len(self.fake_peer("codec-retry", handle)), 3)

    @unittest.skipUnless(Path("/proc/self/fd").is_dir(), "Linux FD accounting")
    def test_authentication_failure_releases_sockets(self):
        def handle(conn, request, count):
            self.assertEqual(request[0], b"AUTH")
            conn.sendall(b"ERR auth-required\n")
        self.assertEqual(len(self.fake_peer("auth-fds", handle)), 40)


class ServerSecurity(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="kouten-security-server-")
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            cls.port = reservation.getsockname()[1]
        cls.log = open(Path(cls.temp.name) / "server.log", "w+")
        cls.proc = subprocess.Popen([
            SERVER, "--id=0", f"--peers=127.0.0.1:{cls.port}",
            "--data=" + cls.temp.name + "/data",
            "--user=alice", "--password=test-secret"],
            stdout=cls.log, stderr=subprocess.STDOUT)
        try:
            for _ in range(100):
                if cls.proc.poll() is not None:
                    raise RuntimeError("test server exited")
                try:
                    with cls.connect() as conn:
                        conn.sendall(b"HEALTH\n")
                        assert line(conn)[0] == b"OK"
                    return
                except OSError:
                    time.sleep(0.05)
            raise RuntimeError("test server not ready")
        except BaseException:
            cls.tearDownClass()
            raise

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        try:
            cls.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.proc.kill()
            cls.proc.wait()
        cls.log.close()
        cls.temp.cleanup()

    @classmethod
    def connect(cls):
        conn = socket.create_connection(("127.0.0.1", cls.port), timeout=3)
        try:
            conn.sendall(b"AUTH alice test-secret\n")
            assert line(conn) == [b"OK", b"auth"]
            return conn
        except BaseException:
            conn.close()
            raise

    def assert_alive(self):
        with self.connect() as conn:
            conn.sendall(b"HEALTH\n")
            self.assertEqual(line(conn)[0], b"OK")

    def test_slow_drip_has_one_cumulative_body_deadline(self):
        slow = self.connect()
        slow.sendall(b"PUTR 4 32 0 raw\ntest")
        stopped = threading.Event()

        def drip():
            while not stopped.wait(0.1):
                try:
                    slow.sendall(b"x")
                except OSError:
                    return

        thread = threading.Thread(target=drip)
        thread.start()
        try:
            time.sleep(0.4)
            started = time.monotonic()
            self.assert_alive()
            self.assertLess(time.monotonic() - started, 1.0)
        finally:
            stopped.set()
            slow.close()
            thread.join(timeout=2)
        self.assertFalse(thread.is_alive())

    def put(self, size, ring=b"test", vector=False):
        with self.connect() as conn:
            payload = b"x" * size
            conn.sendall(f"PUTR {len(ring)} {size} {int(vector)} raw\n".encode() +
                         ring + payload + (struct.pack("<f", 1) if vector else b""))
            result = line(conn)
            self.assertEqual(result[0], b"ID")
            return result

    def batch(self, identifier, count):
        row = b" ".join([identifier[i] for i in [1, 3, 5, 6, 4]]) + b"\n"
        body = row * count
        with self.connect() as conn:
            conn.sendall(f"BGET {count} {len(body)}\n".encode() + body)
            response = line(conn)
            data = exact(conn, int(response[2])) if response[0] == b"BVAL" else b""
        self.assert_alive()
        return response, data

    def test_batch_exact_boundary_and_one_byte_over(self):
        at_limit = self.put(4091)  # five bytes for the item length and newline
        response, body = self.batch(at_limit, 1)
        self.assertEqual(response, [b"BVAL", b"1", b"4096"])
        self.assertEqual(body, b"4091\n" + b"x" * 4091)
        over_limit = self.put(4092)
        self.assertEqual(self.batch(over_limit, 1)[0], [b"ERR", b"bad-request"])

    def test_repeated_id_cannot_amplify_unbounded_response(self):
        identifier = self.put(1024)
        self.assertEqual(self.batch(identifier, 3)[0][0], b"BVAL")
        self.assertEqual(self.batch(identifier, 4)[0], [b"ERR", b"bad-request"])

    def test_list_and_retrieve_bound_retained_payloads(self):
        for op in ("LISTR", "RETRIEVE"):
            ring = ("limit-" + op).encode()
            self.put(3000, ring, vector=True)
            identifier = self.put(3000, ring, vector=True)
            with self.subTest(op=op), self.connect() as conn:
                if op == "LISTR":
                    conn.sendall(b"LISTR " + identifier[1] + b" 2 0\n")
                else:
                    conn.sendall(b"RETRIEVE 1 " + identifier[1] + b" 2 1\n" +
                                 struct.pack("<f", 1))
                self.assertEqual(line(conn), [b"ERR", b"bad-request"])
            self.assert_alive()

    def test_batch_rejects_truncation_trailing_and_overflow(self):
        for count, body in [(1, b""), (0, b"1 0 60 0 1\n"),
                            (1, b"1 4294967296 60 0 1\n"), (1, b"1 0\n")]:
            with self.subTest(count=count, body=body), self.connect() as conn:
                conn.sendall(f"BGET {count} {len(body)}\n".encode() + body)
                self.assertEqual(line(conn), [b"ERR", b"bad-request"])
            self.assert_alive()

    def transaction(self, sizes):
        with self.connect() as conn:
            conn.sendall(b"TXBEGIN\n")
            txid = line(conn)[1]
            ops = b"".join(f"P 1 {i} 60 0 1 {size} 0 raw\n".encode() +
                           b"x" * size + b"\n" for i, size in enumerate(sizes))
            conn.sendall(b"TXCOMMIT " + txid + b" " + str(len(sizes)).encode() +
                         b"\n" + ops)
            response = line(conn)
        self.assert_alive()
        return txid, response

    def test_transaction_aggregate_rejects_without_partial_commit(self):
        txid, response = self.transaction([2047, 2048])
        self.assertEqual(response, [b"ERR", b"bad-request"])
        with self.connect() as conn:
            conn.sendall(b"TXSTATUS " + txid + b"\n")
            self.assertEqual(line(conn), [b"OK", b"UNKNOWN"])
            conn.sendall(b"COUNTR 1\n")
            self.assertEqual(line(conn), [b"COUNT", b"0"])
        self.assertEqual(self.transaction([2047, 2047])[1][0], b"OK")


if __name__ == "__main__":
    unittest.main(verbosity=2)
