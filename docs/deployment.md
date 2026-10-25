# Explicit deployment runbook

This is source, not evidence that anything is deployed. No workflow is triggered
by documentation. No CLI target or actual project reference is committed. Keep
staging and production secrets, project links, approval evidence and private
operational records separate.

## 1. Reconcile existing migration history first

The migration sequence currently ends with `202610250001_sync_club_profile.sql`
and `202610250002_club_profile_lww.sql`, following the original account/cache
migrations. Keep filenames/order. Earlier migrations contain non-idempotent
CREATE statements and must not be blindly replayed on a populated project.

Before **any** linked push, an operator must compare the target's migration ledger
with exact applied schema/function/trigger/ACL definitions and the captured source
content. Provenance allows documented trailing-whitespace/newline normalization;
its normalized hashes establish copy fidelity, not applied-schema equivalence.
Earlier SQL may have been run manually without entries in the CLI ledger.
An ID alone does not prove identical SQL. Preserve backups and a reviewed mapping
of actual applied state to source; keep it out of this public repository.

- If SQL is genuinely absent, apply it only through the reviewed ordered plan.
- If exact SQL was already applied manually, a trusted operator may reconcile the
  migration ledger using the CLI's documented migration-repair procedure **after**
  review. This workflow never automatically repairs history.
- If definitions differ or migration application was partial, stop. Design a
  reviewed forward migration/recovery plan; do not rename IDs, edit historical
  files, drop tables, reset remote databases, or falsely mark absent SQL applied.
- Review pending migration output before authorizing the real push. A dry-run is
  not a proof of semantic schema equivalence or a replacement for reconciliation.

Validate the combined source in disposable staging first, including any Auth
trigger, immutable-history, domain preflight and deletion interactions. A failed
preflight is a blocker, not permission to delete history. See [testing](testing.md).

## 2. Configure secrets and Auth out of band

Hosted runtimes supply `SUPABASE_URL`, `SUPABASE_ANON_KEY` and
`SUPABASE_SERVICE_ROLE_KEY`; do not create redundant custom `SUPABASE_` secrets.
Provider `GOLF_API_KEY`/`GPXZ_API_KEY` values belong only in the selected project's
Edge secrets, entered by the operator. The ignored local transfer file
`supabase/functions/.env.local` is excluded from Git and the app bundle; replace
its values with newly rotated keys before use. Apply them to the chosen project
with Supabase CLI `secrets set --env-file`. Never commit this file or put provider
or service-role credentials in mobile/browser code. Optional
`CORS_ALLOWED_ORIGIN` permits one exact browser origin for deletion; the native
golf-data endpoint independently rejects browser Origins.

Both SQL provider settings start disabled. Keep them disabled during migration,
auth and offline cache validation. Enabling acquisition needs separate approval,
licensing review, budget/cooldown checks, spend monitoring and valid provider keys.
No workflow step enables providers or performs paid smoke calls.

Configure email/Google/approved Apple flow and the exact mobile callback allowlist
using [public Auth setup](auth-setup.md). Local CLI Auth config does not update a
hosted dashboard's provider credentials, SMTP or redirect allowlist.

## 3. Protect GitHub environments before deployment

Create `staging` and `production` GitHub Environments. For **both**, configure
required reviewers, prevent self-approval, restrict deployments to the protected
main branch and protect workflow/source changes with review. Confirm the GitHub
plan supports these controls. The workflow's environment reference **does not
create approval protection**; do not dispatch if enforcement is unavailable.

Each environment needs secrets `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`
and `SUPABASE_DB_PASSWORD`, scoped to its own target. Do not paste their values
into repository files, chat, job inputs or logs. Use appropriately restricted
operator access. After verifying the target's applied SQL and migration ledger
against the repository, set environment variable `MIGRATION_LEDGER_RECONCILED` to
`true`. Re-review and revoke/reset this flag on schema/history changes; it is an
operator assertion, not automated proof.

The `production` environment is also used by
[`auto-migrate-production.yml`](../.github/workflows/auto-migrate-production.yml).
It starts on a push to `main` that changes `supabase/migrations/**`, previews the
pending migration plan, then applies pending migrations. Configure required
reviewers on the production environment so the live database change pauses for
approval; the workflow reference alone does not enforce approval. It fails closed
unless the three production secrets and `MIGRATION_LEDGER_RECONCILED=true` are
configured. `supabase db push` applies all migrations pending in the configured
project, not just the file changed in that push. Keep the production environment restricted to the protected
`main` branch and require review for workflow and migration changes.

The separate [`auto-deploy-golf-data.yml`](../.github/workflows/auto-deploy-golf-data.yml)
workflow deploys only the authenticated `golf-data` Edge Function when its handler,
shared modules, or Supabase config change on `main`. It requires the production
access-token/project-ref secrets and protected `production` environment, but does
not run database migrations or upload provider secrets. Store `GOLF_API_KEY` and
`GPXZ_API_KEY` in the selected Supabase project's Edge Function secrets, out of
band from GitHub Actions.

## 4. Manual release

Select the reviewed main-branch commit in
[the deployment workflow](../.github/workflows/deploy.yml), choose `staging` or
`production`, and explicitly confirm `ledger_reconciled`. Checks must pass and
the selected protected environment must approve before credentials are used.
Production additionally needs successful staging evidence and release approval.

The job links the explicitly selected project, previews `supabase db push
--linked --dry-run`, then executes `supabase db push --linked --yes` and deploys
`golf-data` and `delete-account` with the selected project reference. It does not
use `--include-all`, repair migration history, disable JWT verification, configure
Auth providers, upload provider secrets or enable paid SQL settings. The dry-run
and real push run in the same approved job: reviewers must inspect migration
content/ledger **before approval**, not rely on a pause after the preview.

The setup action selects CLI `2.122.0`, not `latest`. Credentials are provided
only to the steps that need them; checkout and CLI setup receive none. The
database password is not passed to function-deploy steps. GitHub Actions still
use mutable version tags and Deno uses `v2.x`. This is source-reviewed, not an
executed workflow or an immutably pinned production toolchain. Before production,
verify and pin action commits and review exact Deno/SDK resolution and locking;
do not substitute invented commit hashes. Deploy steps are not atomic: if SQL or
one function succeeds and a later step fails, stop and
inspect the target, preserve evidence, and resume only after review. Do not
blindly rerun a partially completed release or reset a remote database.

Both gateways use `verify_jwt = true`; both handlers independently validate the
user online. Test the actual project's asymmetric/legacy signing configuration
in staging. An unexpected gateway 401 is a release blocker, not a reason to add
`--no-verify-jwt` or weaken handler validation. Function deployment success alone
does not prove the mobile user's token is accepted.

## 5. Hosted Supabase GitHub integration is separate

The GitHub Actions workflow above applies migrations and deploys `golf-data` for
relevant protected `main` pushes; it does not connect Supabase's hosted GitHub
integration or create preview branches. If an operator also enables Supabase's
hosted integration, explicitly configure repository access, project,
production/preview branch mapping, repository root and migration/function policy.
GitHub Environment approvals do not automatically govern that integration. Pick
one migration release authority per target so two systems cannot race or bypass
approvals. Never assume Edge functions or Auth settings are automatically
deployed by enabling a database integration.

## Remaining release blockers

Target selection and ledger reconciliation; reviewed disposable SQL harness and
full-schema execution; independent-session races; real Auth/PostgREST and JWT
signing-mode acceptance; complete deletion/retry acceptance; provider licence and
spending approval; backup/restore/retention and monitoring; dependency pinning;
protected-environment setup and production approval. iOS data-service integration
is a separate task and remains unchanged here.
