### Trajectory bag/profile sync

The iOS client also syncs the account's trajectory club bag and personal club
carry/launch overrides through `club_profile`. Apply
`supabase/migrations/202610250001_sync_club_profile.sql` after
`202610230001_sync_domain_validation.sql`. This migration advances the strict
sync capability response to payload validation version 2. Updated clients check
that version before any sync traffic and stop without uploading if it is absent.
Run `tests/sql/club_profile_sync_regression.sql` in the local disposable database
and then in disposable staging after migration. Do not edit an applied migration;
use a reviewed forward-only migration for subsequent DTO changes.

# Golf PinTheory — Supabase backend source

Standalone deployment source for account sync, account deletion, service-only
account metrics and the authenticated shared GolfAPI/GPXZ cache. This repository
does **not** contain the iOS app or the localhost admin GUI.

**Status: source consolidation, not a deployment.** Original migrations and tests
are preserved, including historical review/unexecuted comments. Offline source
tests are not proof of a working hosted installation. No git remote, push, hosted
project link, remote migration, function deployment or paid-provider call is made
by creating this scaffold. The iOS repository remains untouched; the sibling
local-admin-server was separately reduced to a loopback-only Supabase dashboard.
The app is not switched to this data endpoint by this work.

## Contents

- [supabase/config.toml](supabase/config.toml): local CLI settings; private schemas
  remain unexposed, both Edge gateways retain JWT verification.
- [historical sync foundation](supabase/migrations/202610190001_sync_foundation.sql),
  [deletion](supabase/migrations/202610210001_account_deletion.sql),
  [domain validation](supabase/migrations/202610230001_sync_domain_validation.sql),
  [account metrics](supabase/migrations/202610240001_admin_account_metrics.sql):
  content copied; whitespace normalized, with original migration IDs.
- [shared cache migration](supabase/migrations/202610240002_shared_data_cache.sql):
  the new forward migration for hosted cache coordination, budgets and admin reports.
- [golf-data entry point](supabase/functions/golf-data/index.ts) and existing
  shared modules; [delete-account entry point](supabase/functions/delete-account/index.ts).
- [sync contract](docs/sync-contract.md), [public Auth setup](docs/auth-setup.md),
  [source provenance](docs/source-provenance.md), [validation](docs/testing.md),
  [deployment runbook](docs/deployment.md), [completion state and executed checks](docs/scaffold-status.md).

## Local source checks

Prerequisites: Node.js 22+ and Deno 2. The existing package uses Node built-ins;
no npm dependency installation is needed. From this repository, run `npm test`
(Edge and provenance suites) and `deno task check`. To run provenance alone, use
`node --test tests/provenance.test.js`.

Node tests use injected transports/fakes, not paid services. Provenance checks
hash normalized committed content and optionally compare an explicitly selected
sibling checkout after per-line `trimEnd()` normalization. Deno checks both entry
points without starting them; initial dependency
resolution can download public npm packages, but does not call Supabase or paid
providers. The original deletion import uses the major-version range `@2` and
is intentionally unchanged; Deno uses its global dependency cache rather than a
local node_modules directory, and locking is disabled in this scaffold. Review and
pin a dependency-resolution policy before a production release.

[PR CI](.github/workflows/ci.yml) runs these source checks with no hosted secrets.
It does **not** execute SQL or deploy. Disposable SQL, independent-session races,
real Auth/JWT gateway compatibility and deletion lifecycle acceptance remain
separate release gates in [docs/testing.md](docs/testing.md).

## Configuration and data boundaries

Hosted Supabase provides `SUPABASE_URL`, `SUPABASE_ANON_KEY` and
`SUPABASE_SERVICE_ROLE_KEY` to the runtime. Provider keys belong in target-specific
Edge secrets, never SQL rows, mobile clients, browser code or this repository.
[supabase/functions/.env.example](supabase/functions/.env.example) is a local-only
placeholder reference. Leave providers unconfigured for offline work; both
`pintheory_data.settings.enabled` defaults are **false**. A key alone is not
permission to enable paid acquisition.

Keep `pintheory_sync`, `pintheory_admin` and `pintheory_data` out of Data API and
Realtime exposure. User identity is verified online independently inside each
handler. `golf-data` requires a verified nonanonymous user and SQL account checks
for cache hits as well as misses; it has no shared server-token fallback. Its
native route prefix is `/functions/v1/golf-data/api/v1/`. Browser Origin requests
are denied. Shared provider data is not an individual user's sync data and remains
when that account is deleted; per-user telemetry has separate retention.

## Deployment — operator approval required

**Do not blindly apply the copied historical IDs to an existing project.** Old
SQL may already have been applied manually without a matching CLI migration
ledger. Compare exact applied definitions and migration history, resolve drift
through reviewed forward SQL, and reconcile the ledger first. Do not drop tables,
replay `CREATE` migrations, rename IDs or mark unapplied SQL as applied to make a
push succeed. See [docs/deployment.md](docs/deployment.md).

The [manual workflow](.github/workflows/deploy.yml) offers `staging` or
`production`, uses GitHub Environment secrets, and requires explicit migration
reconciliation. Configure **required reviewers, prevent self-approval, and
deployment branch protection** for both environments before using it. YAML alone
cannot create those approval rules. Production also requires staging evidence,
backups, signing-key compatibility, licensing/spend controls and release approval.

Deployment credentials are scoped to individual validation/CLI steps, not the
whole job or checkout/setup actions. The CLI version is fixed at `2.122.0`.
Actions still use mutable version tags and Deno uses `v2.x`: this is a
source-reviewed workflow, **not an immutably pinned production toolchain or an
executed GitHub deployment**. Review verified action commit pins, exact Deno/SDK
resolution and a lock policy before production; no unverified commit SHA is used.

Hosted **Supabase GitHub integration is separate**: this scaffold neither installs
nor connects it and makes no automatic-deploy assumption. If an operator later
enables it, configure its project/branch/root and release policy explicitly and
avoid competing with the manual workflow. Merging a PR here does not authorize
any remote deployment.

## Scope exclusions

No private operations/recovery material, provider exports, local project metadata,
real URLs/project references/keys/user IDs, credentials or database dumps are
included. Synthetic SQL fixture identities are retained verbatim. Source originals
stay in the iOS repository; do not remove them as part of this consolidation.
