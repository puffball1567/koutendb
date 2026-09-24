# KoutenDB v0.15.0

This release hardens KoutenDB's network, authentication, and foreign-driver
boundaries. It adds bounded aggregate framing, fail-safe connection recovery,
and explicit handling for writes whose remote outcome is unknown.

## Security And Transport

- Bound aggregate cluster transactions, batch responses, ring-list payloads,
  retrieval payloads, and multi-frame client responses.
- Reject authentication and galaxy header delimiters without echoing supplied
  credentials in validation errors.
- Require TLS for authenticated non-loopback listeners by default. SECRET_KEY
  remains an additional authentication and frame-protection layer, not a TLS
  replacement.
- Apply cumulative header and body read deadlines so slow-drip clients cannot
  retain the request loop indefinitely.
- Close failed or malformed connections instead of reusing an uncertain frame
  boundary.

## Write Safety

Reads and explicitly fenced or deduplicated internal control operations retain
one bounded transport retry. Ordinary mutations are no longer replayed
automatically after a lost response because the server may already have
committed the write. Nim callers receive
`KoutenIndeterminateWriteError` and can reconcile by application identity or a
subsequent read before deciding whether to issue another mutation.

Cluster transactions are the deliberate exception: their stable transaction ID
and exact-intent collision check make an identical commit replay safe. Fenced
coordinator controls and deduplicated Universe events have the same explicit
protocol guarantee.

## Validation

The new wire security matrix covers:

- exact and over-limit aggregate boundaries;
- transaction rejection without partial commit;
- truncated, trailing, malformed, and oversized frames;
- lost write acknowledgements and bounded safe-request retries;
- failed-authentication descriptor cleanup;
- codec renegotiation after reconnect;
- slow-drip request recovery;
- C ABI credential and galaxy injection rejection.

The release candidate is accepted only after the Linux and macOS CI suites pass
on the release commit. This is a focused transport and boundary review, not a
claim that independent penetration testing or every deployment threat has been
completed.

See the [v0.15 Security Review](https://github.com/puffball1567/koutendb/blob/v0.15.0/docs/v0.15-security-review.md),
[Threat Model](https://github.com/puffball1567/koutendb/blob/v0.15.0/docs/threat-model.md), and
[Security Validation Matrix](https://github.com/puffball1567/koutendb/blob/v0.15.0/docs/security-validation.md).
