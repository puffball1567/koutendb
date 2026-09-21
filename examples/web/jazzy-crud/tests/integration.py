"""Real HTTP -> Jazzy -> authenticated persistent KoutenDB contract matrix."""

import concurrent.futures
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[4]
SERVER, API = map(lambda value: str(Path(value).resolve()), sys.argv[1:3])


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def stop(proc):
    if proc is None or proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)


def run():
    with tempfile.TemporaryDirectory(prefix="kouten-jazzy-test-") as directory:
        work = Path(directory)
        db_port, http_port = free_port(), free_port()
        while http_port == db_port:
            http_port = free_port()
        base = f"http://127.0.0.1:{http_port}"
        password, secret = "jazzy-fixture-password", "jazzy-fixture-secret"
        env = dict(os.environ, APP_ENV="production", DEV_UI_ENABLED="false",
                   CSRF_ENABLED="false", LOG_LEVEL="NONE", MAX_UPLOAD_SIZE="1",
                   BIND_ADDRESS="127.0.0.1", PORT=str(http_port),
                   KOUTEN_PEERS=f"127.0.0.1:{db_port}", KOUTEN_USER="demo",
                   KOUTEN_PASSWORD=password, KOUTEN_SECRET_KEY=secret,
                   KOUTEN_GALAXY="jazzy-demo", KOUTEN_RING="demo/tasks",
                   KOUTEN_TLS="false", KOUTEN_TLS_CA_FILE="", KOUTEN_TLS_SERVER_NAME="")
        processes, logs = [], []

        def start(command, environment, label):
            log = open(work / f"{label}-{len(logs)}.log", "wb")
            logs.append(log)
            proc = subprocess.Popen(command, cwd=work, env=environment,
                                    stdout=log, stderr=subprocess.STDOUT)
            processes.append(proc)
            return proc

        def start_db(tls=False):
            args = [SERVER, "--id=0", f"--peers=127.0.0.1:{db_port}",
                    f"--data={work / 'data'}", "--disk-backed", "--slow-tick=0.05",
                    "--galaxy=jazzy-demo", "--user=demo"]
            if tls:
                args += [f"--tls-cert={work / 'cert.pem'}",
                         f"--tls-key={work / 'key.pem'}"]
            proc = start(args, env, "db")
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                assert proc.poll() is None, "koutend exited during startup"
                try:
                    with socket.create_connection(("127.0.0.1", db_port), timeout=0.2):
                        return proc
                except OSError:
                    time.sleep(0.05)
            raise AssertionError("koutend startup timeout")

        def request(path, method="GET", payload=None, expected=200, raw=None):
            data = raw if raw is not None else (None if payload is None else json.dumps(payload).encode())
            req = urllib.request.Request(base + path, data=data, method=method,
                                         headers={"Content-Type": "application/json"})
            try:
                response = urllib.request.urlopen(req, timeout=20)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                body = response.read().decode()
                assert response.status == expected, (method, path, response.status, body)
                assert password not in body and secret not in body, "credential disclosure"
                return json.loads(body) if body else None

        def start_api(environment=env, health=200):
            proc = start([API], environment, "api")
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                assert proc.poll() is None, "Jazzy exited during startup"
                try:
                    request("/health", expected=health)
                    return proc
                except (OSError, AssertionError):
                    time.sleep(0.1)
            raise AssertionError("Jazzy startup/health timeout")

        try:
            db = start_db()
            api = start_api()
            subprocess.run(["node", str(ROOT / "examples/web/rekt-crud/tests/crud-smoke.mjs")],
                           env=dict(env, BASE_URL=base), check=True, timeout=120)
            print("shared CRUD/locality contract PASS", flush=True)

            for value in [None, [], {}, {"title": ""}, {"title": "x" * 121},
                          {"title": 2}, {"title": "valid", "completed": "yes"},
                          {"title": "valid", "category": "../private"},
                          {"title": "valid", "tags": ["x"] * 7},
                          {"title": "valid", "tags": ["<script>"]}]:
                request("/tasks", "POST", raw=json.dumps(value).encode(), expected=400)
            request("/tasks", "POST", raw=b"{broken", expected=400)
            request("/tasks", "POST", raw=b" " * 65537, expected=400)
            for value in ["bad", "1_4294967296_0_0", "1_0_4294967296_0",
                          "1_0_0_nan", "1_0_0_inf", "1_0_0_-1"]:
                request("/tasks/" + value, expected=400)
            request("/tasks/0_0_0_0", expected=404)
            assert request("/tasks")["count"] == 0, "invalid input mutated storage"
            print("invalid JSON/types/limits/IDs and no side effects PASS", flush=True)

            def create(index):
                title = f"parallel-{index}-\u65e5\u672c\u8a9e-\U0001f680"
                item = request("/tasks", "POST", {"title": title, "category": "research"}, 201)
                assert request("/tasks/" + item["id"])["title"] == title
                return item

            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
                items = list(executor.map(create, range(32)))
            assert len({item["id"] for item in items}) == 32
            assert {item["id"] for item in request("/tasks")["items"]} == {item["id"] for item in items}
            sample = items[0]
            sample = request("/tasks/" + sample["id"], "PUT", dict(sample, completed=True))
            assert sample["completed"]
            print("32 concurrent Unicode writes/readback and exact list PASS", flush=True)

            stop(db)
            request("/health", expected=503)
            request("/tasks/" + sample["id"], expected=503)
            db = start_db()
            assert request("/tasks/" + sample["id"])["completed"]
            stop(api)
            api = start_api()
            assert request("/tasks")["count"] == 32
            print("database outage, recovery, API restart and persistence PASS", flush=True)

            stop(api)
            api = start_api(dict(env, KOUTEN_PASSWORD="wrong-password"), health=503)
            request("/tasks", "POST", {"title": "must not write"}, 503)
            stop(api)
            stop(db)
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                            "-days", "1", "-subj", "/CN=localhost",
                            "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
                            "-addext", "extendedKeyUsage=serverAuth",
                            "-keyout", str(work / "key.pem"), "-out", str(work / "cert.pem")],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            db = start_db(tls=True)
            tls_env = dict(env, KOUTEN_TLS="true", KOUTEN_TLS_CA_FILE=str(work / "cert.pem"),
                           KOUTEN_TLS_SERVER_NAME="localhost")
            api = start_api(tls_env)
            assert request("/tasks")["count"] == 32
            tls_item = request("/tasks", "POST", {"title": "verified TLS"}, 201)
            assert request("/tasks/" + tls_item["id"])["title"] == "verified TLS"
            request("/tasks/" + tls_item["id"], "DELETE", expected=204)
            stop(api)
            api = start_api(dict(tls_env, KOUTEN_TLS_SERVER_NAME="wrong.invalid"), health=503)
            request("/tasks", expected=503)
            stop(api)
            api = start_api(dict(tls_env, KOUTEN_TLS_CA_FILE=""), health=503)
            request("/tasks", expected=503)
            print("auth rejection, verified TLS, wrong hostname and untrusted CA PASS", flush=True)
        finally:
            for proc in reversed(processes):
                stop(proc)
            for log in logs:
                log.close()
            assert not list(work.glob("*.sqlite*")), "unexpected SQL persistence"
            for path in work.glob("*.log"):
                content = path.read_text(errors="replace")
                assert password not in content and secret not in content, "credential leaked in service log"


if __name__ == "__main__":
    run()
    print("Jazzy integration matrix PASS")
