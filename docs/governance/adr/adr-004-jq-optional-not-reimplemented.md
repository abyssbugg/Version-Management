# ADR-004: `jq` Stays Optional; No Pure-Bash JSON Parser

**Status:** Accepted (adjudicated 2026-07-04, MASTER_AUDIT §5.3)

## Context

Parts of the suite read or emit small JSON payloads (cache metadata,
transaction `metadata.json`, template generation). One audit (GLM-5.2)
proposed replacing the optional `jq` dependency with a hand-rolled pure
-bash JSON parser so the suite would work on hosts without `jq`.

## Decision

**`jq` remains an optional dependency with graceful degradation; no JSON
parser is reimplemented in Bash.** Hand-rolled JSON parsing in shell
trades a well-audited, battle-tested optional dependency for a fragile
one-off parser (quoting, escapes, unicode, number edge cases) — a worse
trade for a tool whose correctness matters when it is used to gate
machine mutations.

Where the suite must maintain structured metadata, it deliberately uses
formats that shell handles safely instead of JSON:

- The transaction file registry (`files.tsv`) is tab-delimited with
  newline/tab characters rejected on input (fail closed).
- The audit journal is tab-delimited (see `lib/backup.sh`,
  `_txn_journal`).
- Transaction `metadata.json` is *written* only, and only with
  grammar-validated values interpolated, never parsed back by shell.

## Consequences

- Features that would require real JSON *parsing* either degrade
  gracefully without `jq` or are restructured to tab-delimited metadata.
- Anyone proposing a Bash JSON parser must bring a new ADR; the fragile
  -dependency argument only justifies the swap if a hardened parser
  (not a one-off) is used.
- `jq`-dependent code paths must guard with `command -v jq` and provide
  a documented fallback, consistent with the M1 library contract of
  explicit failure rather than silent breakage.
