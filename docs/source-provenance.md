# Source provenance

Captured 2026-10-24 from the sibling iOS repository named
**fairwayvector-golfpintheory**. This is a copy, not a move: originals remain in
place and no iOS or local-admin-server source is changed by consolidation.

[docs/source-provenance.json](source-provenance.json) records the source path,
destination path and fingerprints of all eleven files. Copy policy: **content
copied; whitespace normalized**. The `sha256` field preserves the original source
byte fingerprint at capture (including its end-of-file convention); it is not a
claim of destination byte identity. `normalizedSha256` verifies copied content.

Normalization decodes UTF-8, splits on CRLF or LF, applies `trimEnd()` to each
line, rejoins with LF, then applies `trimEnd()` to the whole text. Only trailing
line whitespace and terminal whitespace/newlines are ignored. Leading indentation,
internal spacing, interior blank lines, SQL/TypeScript tokens and comments remain
significant. All eleven copies were compared to the existing originals under
this rule; none is truncated or missing content. A copied SQL indentation mismatch
was restored to the original rather than widening the normalization rule.

| Original path within iOS repository                        | Destination                                                                         |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| backend/migrations/202610190001_sync_foundation.sql        | [sync foundation](../supabase/migrations/202610190001_sync_foundation.sql)          |
| backend/migrations/202610210001_account_deletion.sql       | [account deletion](../supabase/migrations/202610210001_account_deletion.sql)        |
| backend/migrations/202610230001_sync_domain_validation.sql | [domain validation](../supabase/migrations/202610230001_sync_domain_validation.sql) |
| backend/migrations/202610240001_admin_account_metrics.sql  | [account metrics](../supabase/migrations/202610240001_admin_account_metrics.sql)    |
| backend/tests/account_deletion_regression.sql              | [deletion regression](../tests/sql/account_deletion_regression.sql)                 |
| backend/tests/admin_account_metrics_regression.sql         | [metrics regression](../tests/sql/admin_account_metrics_regression.sql)             |
| backend/tests/concurrency_regression.sql                   | [manual concurrency regression](../tests/sql/concurrency_regression.sql)            |
| backend/tests/domain_payload_regression.sql                | [domain regression](../tests/sql/domain_payload_regression.sql)                     |
| backend/tests/security_regression.sql                      | [security regression](../tests/sql/security_regression.sql)                         |
| supabase/functions/delete-account/index.ts                 | [delete-account handler](../supabase/functions/delete-account/index.ts)             |
| backend/CONTRACT.md                                        | [sync wire contract](sync-contract.md)                                              |

The four historical migration filenames and IDs are unchanged. Their status
comments and the contract's historical caveats are preserved in content, not updated
to imply a deployment or a successful hosted test. Future runtime corrections
require reviewed forward migrations, not editing imported history.

The existing shared-cache migration, Edge modules, package manifest, Edge tests
and cache SQL test were already present here and are not imported or overwritten.
The auth guide is a new, redacted public summary, not a verbatim copy of the app's
operator guide. No operations/recovery scripts, provider exports, linked-project
metadata, local configuration, credentials or private user data were imported.

## Verification

Run `node --test tests/provenance.test.js` from this repository. CI verifies the
committed normalized destination hashes without requiring another repository. Optional local
cross-check: set `LEGACY_SOURCE_ROOT` to an operator-selected checkout of the
original iOS repository and run the same test. It only reads the eleven listed
paths and compares normalized text directly as well as checking both against the
captured normalized hashes. Raw-byte-only whitespace differences do not fail.
Regression tests ensure normalization does not hide missing lines, token changes,
leading indentation changes or changes to internal spacing/interior blank lines.

Normalized hash agreement proves content fidelity under this whitespace policy,
**not database correctness or deployment**.
The original fixtures contain synthetic identities; they are not production
exports. See [validation and release gates](testing.md).
