#!/usr/bin/env python3
"""Validate release discovery without installing packages or contacting servers."""

import subprocess
import sys


def output(*args):
    return subprocess.run(
        [sys.argv[1], "driver", *args], check=True, capture_output=True, text=True
    ).stdout


expected = {
    "rust": ("v0.2.0", "https://github.com/puffball1567/koutendb-rust", "cargo add koutendb"),
    "node": ("v0.1.5", "https://github.com/puffball1567/koutendb-js", "npm install koutendb"),
    "php": ("v0.2.0", "https://github.com/puffball1567/koutendb-php", "composer require koutendb/koutendb"),
    "cpp": ("v0.2.0", "https://github.com/puffball1567/koutendb-cpp", "git clone https://github.com/puffball1567/koutendb-cpp.git"),
    "python": ("v0.3.0", "https://github.com/puffball1567/koutendb-python", "python3 -m pip install koutendb"),
    "go": ("v0.1.0", "https://github.com/puffball1567/koutendb-go", "go get github.com/puffball1567/koutendb-go@v0.1.0"),
}

listing = output("list").splitlines()
assert len(listing) == len(expected) + 1, listing
for language, (version, repository, install) in expected.items():
    assert any(row.startswith(language + "\t") for row in listing), language
    for action in ("info", "install"):
        result = output(action, language)
        assert version in result, (language, result)
        assert f"repository: {repository}\n" in result, (language, result)
        assert f"install: {install}\n" in result, (language, result)
        assert "repository-local" not in result, (language, result)

node = output("info", "node")
assert "GitHub: v0.2.0" in node and "not yet published to npm" in node, node
assert "CGO_ENABLED=0" in output("info", "go")
assert "--no-default-features --features tcp" in output("info", "rust")
assert output("info", "GO") == output("info", "go")
bad = subprocess.run(
    [sys.argv[1], "driver", "info", "unreleased-language"], capture_output=True, text=True
)
assert bad.returncode != 0, bad.stdout
print("driver registry: six release entries, install hints and invalid language PASS")
