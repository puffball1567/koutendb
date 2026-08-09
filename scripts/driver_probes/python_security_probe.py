"""Cross-driver TLS/auth probe for the external KoutenDB Python package."""

from __future__ import annotations

import os

from koutendb import KoutenClient


def value(name: str) -> str:
    return os.environ.get(name, "")


def enabled(name: str) -> bool:
    return value(name) == "1"


def main() -> None:
    client = KoutenClient.connect(
        value("KOUTEN_PROBE_PEERS"),
        timeout=5.0,
        username=value("KOUTEN_PROBE_USER"),
        password=value("KOUTEN_PROBE_PASSWORD"),
        secret_key=value("KOUTEN_PROBE_SECRET_KEY"),
        tls=enabled("KOUTEN_PROBE_TLS"),
        tls_ca_file=value("KOUTEN_PROBE_CA_FILE"),
        tls_server_name=value("KOUTEN_PROBE_SERVER_NAME"),
        tls_insecure_skip_verify=enabled("KOUTEN_PROBE_INSECURE"),
    )
    try:
        doc_id = client.put_json("secure/demo", {"probe": "python"})
        value_read = client.get_json(doc_id, node=0)
        if value_read != {"probe": "python"}:
            raise RuntimeError("Python TLS/auth roundtrip returned different data")
        print("SUCCESS")
    finally:
        client.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # The harness classifies a closed failure path.
        print(f"REJECT:{str(exc)[:120]}")
