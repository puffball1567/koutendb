---
layout: page
title: Container Persistence and Security Validation
---

# Container Persistence and Security Validation

KoutenDB keeps an explicit Docker matrix for the persistent server boundary:

```sh
scripts/container_security_matrix.sh
```

The script builds `examples/compose/Dockerfile`, creates isolated test-only
containers, a network, and named volumes, then removes every resource on exit.
Set `KOUTEN_CONTAINER_KEEP_IMAGE=1` only when retaining the image for local
debugging is intentional.

## Covered Matrix

| Boundary | Verification |
|---|---|
| Image | `koutend` and `koutencli` compile with `-d:ssl` on Nim 2.2.10. |
| Storage | One strong-durability, disk-backed store runs on a Docker named volume. |
| Restart | A JSON record remains exact after restarting the same container. |
| Network | The client fails while the server is disconnected from the Docker network and recovers after reconnect. |
| Replacement | A newly created container opens the original named volume and reads the same record. |
| TLS | A test CA succeeds; plaintext, a foreign CA, the wrong hostname, and an expired certificate fail closed. |
| Authentication | Valid `username + password + secret key` succeeds; wrong username, password, secret key, and a missing secret key fail. |
| Authorization | An allowed ring write succeeds and a write outside the configured ring prefix fails. |
| Rotation | New password and secret-key files take effect after container replacement; old credentials fail. |
| Offline recovery | After server shutdown, `koutencli verify --segments --json` opens and verifies the named volume. |
| Audit | Authentication and authorization denials remain in the persistent audit JSONL. |

## Local Result

The v0.12 development matrix completed on an Ubuntu host using Docker 29.6.2
with the Docker Linux engine. Every row above passed, and the cleanup check
reported no remaining test container, network, volume, image, or dangling
image.

This is process/container evidence on one local engine. It does not replace
multi-host network testing, cloud-volume failure injection, or a managed PKI
certificate-rotation exercise.
