# Validation and release gates

## Automated source checks

From the repository root: `npm test` runs the offline Edge and provenance suites;
`node --test tests/provenance.test.js` checks the eleven normalized imported file hashes
and the whitespace-normalization boundaries;
`deno task check` checks both Edge entry points. Provenance is included in the
package test script and therefore in CI. No sibling checkout is
required. `LEGACY_SOURCE_ROOT` optionally enables a read-only original-source
comparison using per-line `trimEnd()` and end-of-file whitespace normalization.
Exact source-byte hashes remain capture metadata, not a destination equality gate.
See [source provenance](source-provenance.md).

These checks do not start a function, invoke a provider, prove SQL correctness,
validate SMTP or exercise hosted JWTs. Deno may download public dependencies.
The unchanged deletion function is checked but is not covered by the injected
golf-data Node transport suite. Full lifecycle integration is still required.

## Disposable SQL only

Use a new throwaway local Supabase database or a specifically approved disposable
staging project with **no valuable users/data**. The SQL assumes Supabase Auth
schemas/functions/API roles and the trusted `postgres` migration owner; plain
PostgreSQL without an explicit reviewed Auth fixture is not equivalent. Do not
point any of these tests at production. Some take table locks, TRUNCATE cache
tables or commit setup fixtures. Never disable history triggers to force a pass.

1. Review and apply all migrations in filename order on a fresh database.
   Local Supabase CLI needs its normal local container runtime. Any local reset
   is destructive and must explicitly target only the disposable local instance,
   never a linked remote. There is deliberately no automatic remote SQL test job.
2. Run each rollback-contained script separately as `postgres`, with psql startup
   files disabled, stop-on-first-error and PL/pgSQL assertions enabled. Review
   [security](../tests/sql/security_regression.sql),
   [deletion](../tests/sql/account_deletion_regression.sql),
   [domain](../tests/sql/domain_payload_regression.sql),
   [metrics](../tests/sql/admin_account_metrics_regression.sql), and
   [shared cache](../tests/shared_data_cache.sql),
   [club profile](../tests/sql/club_profile_sync_regression.sql), and
   [club profile timestamp](../tests/sql/club_profile_lww_regression.sql),
   [private catalog import](../tests/sql/catalog_import_regression.sql), and
   [catalog search](../tests/sql/catalog_search_regression.sql) after applying all
   catalog migrations through `202610300005_catalog_club_name_only_search.sql`.
   Do not loop over every SQL file:
   the concurrency script is explicitly **not** a single-session executable.
3. Execute [concurrency sections](../tests/sql/concurrency_regression.sql) in
   independent connections, following its labels and variants. Cache concurrency
   variants are described at the end of the existing cache test: same key,
   rollback, different-key budget contention, and concurrent active-job limits.
   Record commit/rollback/blocking evidence; sequential calls do not prove races.
4. Test the full combined schema, not a foundation-only approximation. Legacy
   comments preserve their capture-time status and must not be rewritten to
   claim a pass. Report any migration/fixture/immutable-history failure as a
   blocker; investigate with a reviewed forward change or separately approved
   test correction. This consolidation does not alter historical SQL to work
   around runtime errors.

The scaffold CI intentionally does **not** run disposable SQL yet. A reviewed
reproducible database harness and recorded full-schema results remain a release
gate. Do not infer that tests copied here, or previous local experiments outside
this checkout, passed in a hosted Supabase environment.

## Staging integration before production

- Real signed user sessions through gateway and independent online user validation;
  missing/expired/wrong-project/anonymous/deleted/blocked user rejection.
- Verify asymmetric signing-key compatibility without removing JWT checks.
- Two-user sync isolation, DTO validation, replay/CAS/tombstone behavior and
  real PostgREST numeric-string shapes.
- Recent-auth deletion, blocked sync while deleting, service-only purge, Auth
  identity removal and retry after partial failure. Shared cache must remain,
  while individual rate telemetry is removed according to its lifecycle.
- Cache-only hits/misses with providers disabled, budgets and failure cooldowns,
  ambiguous-dispatch fail-closed behavior, stale owner fencing, aggregate-only
  admin ACLs and provider-response validation. Use injected transports/fakes;
  paid smoke tests require separate explicit approval and tiny approved limits.
- Endpoint still serves an authorized hosted cache hit with the localhost admin
  computer off; no iOS cutover is implied by this acceptance test.
- Backups/restore, retention, monitoring, storage/egress limits, provider licences,
  dependency-resolution review, and documented rollback/recovery ownership.

Record the exact commit, schema history, runtime versions, commands and outcomes
in a release review without storing user data, live tokens or private exports.
