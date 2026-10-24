# Golf PinTheory sync wire contract v1 — staging validation source

Status: client DTOs and a forward-only domain-validation migration are implemented
in source; **the migration is not deployed or database-tested**. Do not enable sync
for valuable data until the documented disposable-staging sequence passes.

## Transport and identity

Supabase PostgREST authenticated POST RPCs in `public`:
`pintheory_sync_capabilities`, `pintheory_sync_mutate`, `pintheory_sync_changes`, and
`pintheory_begin_account_deletion`. The client checks capability versions before
any sync RPC; an older server fails closed before sending records. Ownership comes exclusively from verified
`auth.uid()`, never a request owner, email, or payload field. Requests require a
user session JWT; a publishable project key alone is insufficient. The private
`pintheory_sync` schema must NOT be exposed through the Data API.

UUIDs are canonical UUID strings. The client generates stable `record_id` and
`mutation_id` UUIDs and persists them before sending. A UUID identifies one record
across all kinds for a user. Kind cannot change. Same UUID in another account is
a separate identity. Never use names, persistentModelID, or email as identity.
Deterministic singleton/default-wedge identities and additive model backfill are
client work still to be designed; the server does not seed defaults.

Every revision, sequence and cursor is a **decimal string**, not a JSON number:
`"0"` or a positive base-10 integer without leading zeros, at most signed bigint 9223372036854775807. This avoids JavaScript/Android double precision loss.
Schema version and page limit are JSON integer numbers. Timestamps are PostgreSQL
JSON timestamptz strings with offset; parse ISO-8601 with fractional seconds.

## Mutate

All seven arguments are required. Exact request example:

```json
{
  "p_mutation_id": "10000000-0000-4000-8000-000000000001",
  "p_record_id": "20000000-0000-4000-8000-000000000001",
  "p_kind": "wedge",
  "p_expected_revision": "0",
  "p_operation": "put",
  "p_schema_version": 1,
  "p_payload": { "label": "Example only, not an approved wedge DTO" }
}
```

Kinds: `golfer_profile`, `club_profile`, `wedge`, `custom_club`, `custom_course`,
`custom_tee`, `played_round`, `handicap_round`, `flag_position`.

- `put` replaces the whole payload (not a merge/patch). Expected `"0"` creates
  only if the UUID has never existed. Any existing row, including tombstones,
  needs its current revision. A matching put on a tombstone explicitly restores
  it. Clients must expose conflict resolution, not automatically restore it.
- `delete` requires `{}` payload and an existing matching record revision.
  The stored payload/source link/created timestamp are preserved; `deleted_at`
  is set server-side. Deleting a missing row returns conflict with null current.
  Re-deleting a tombstone with a new matching revision is accepted as another event.
- Every applied mutation consumes exactly one per-user sequence. That sequence
  is the record's revision, not a per-record counter. Sequences reflect serialized
  server commits, never client clocks. Conflicts/retries consume no sequence.
- Payload must be a JSON object, serialized JSONB text at most **65,536 bytes**.
  SQL NULL, arrays, scalar values and schema versions other than 1 are rejected.
  This byte limit is **backend-authoritative**, not a limit on a client's JSON
  encoding. Swift slash/Unicode escaping and PostgreSQL whitespace differ. Clients
  must not reject accepted records, receipts, feed pages or journal reloads by
  re-encoding payloads and comparing to 65,536. The Swift foundation deliberately
  applies no local payload-size cap, even to outgoing mutations; an oversized put
  can be queued but is rejected by SQL and must not be marked synced. This is not
  a transport response/body/depth/memory bound; those remain separate release gates.
- Every payload number, recursively through objects and arrays, must be an exact
  finite decimal with **absolute value <= 10^20** and **value = round(value, 16)**
  (no more than 16 fractional decimal places after trailing-zero normalization).
  Zero, both signs, exponent notation and insignificant trailing zeros are allowed;
  the smallest nonzero magnitude is 10^-16. Booleans remain JSON booleans, not numbers.
  Examples accepted: `9007199254740993.125`, `57.6234567890123456`, `1e20`, `1e-16`.
  Examples rejected: `1e200`, `100000000000000000001`, `1e-17`, `57.12345678901234567`.
  This is NOT an IEEE-754 safe-integer contract: use exact decimal parsing/storage,
  never an intermediate Double. All allowed values fit Swift Decimal exactly
  (at most 36 significant digits below the magnitude boundary; 10^20 itself has 21).
  SQL enforces the domain before receipts/events and on stored record payloads;
  Swift validates decoded Decimal values, direct constructions, encoding and
  journal writes recursively. Foundation Decimal decoding is not a raw-token
  arbitrary-precision validator for untrusted out-of-contract numbers that may
  already have rounded during decoding; server ingress validation is essential.
  The initial migration is still undeployed, so no old out-of-domain feed exists
  to migrate. Any deployed variant needs a forward migration plus history/receipt
  audit and a recovery plan before this assumption is valid.
  The base migration alone does NOT provide content field allowlisting. The
  forward-only `202610230001_sync_domain_validation.sql` migration adds strict
  per-kind allowlists and field/range checks for the current iOS profile, wedge,
  custom club/course/tee, saved scorecard, and handicap-round DTOs. It rejects
  unknown kinds/fields, including flags and club-profile records not yet approved.
  It also checks custom course/tee references against active parent records owned
  by the same account. It preflights current records, change events and immutable
  receipts; if old generic payloads exist, it aborts without rewriting or deleting
  them. The base migration by itself is unsafe for client uploads. Preferences,
  active drafts, downloaded catalog data and provider geometry remain excluded.

Record envelope (identical in applied responses, conflicts and events):

```json
{
  "record_id": "20000000-0000-4000-8000-000000000001",
  "kind": "wedge",
  "schema_version": 1,
  "payload": { "label": "Example only, not an approved wedge DTO" },
  "revision": "1",
  "created_at": "2026-10-19T12:00:00+00:00",
  "updated_at": "2026-10-19T12:00:00+00:00",
  "deleted_at": null
}
```

Response alternatives (RECORD means the envelope above, not literal wire text):

| status            | Exact top-level keys                                                        |
| ----------------- | --------------------------------------------------------------------------- |
| `applied`         | `status`, `mutation_id`, `record: RECORD`                                   |
| `conflict`        | `status`, `mutation_id`, `current: RECORD or null`                          |
| `source_conflict` | `status`, `mutation_id`, `current: RECORD or null`, `source_record: RECORD` |

A revision or kind mismatch returns `conflict`, never overwrites the existing
record. Missing record with nonzero expected revision also conflicts. The receipt
stores the original request (including the losing payload) **and** response,
preserving both submitted and server versions. It is private, not a client conflict
browser. Clients must durably retain their outbox/local version and response in a
conflict store before acknowledging or showing resolution; no automatic merge or
duplicate stats/HCP entry. Resolution uses a new mutation ID and current revision.

An identical mutation ID/request returns the exact original JSON response, even
if the current record has since changed. JSONB equality ignores object key order
and formatting; array order matters. A different request using that mutation ID
raises SQLSTATE `22023`, never replays success. IDs are scoped to UID and must be
kept forever within that account. Do not generate a new ID on network timeout.
Account blocking takes precedence over replay. Malformed/auth/state errors raise
SQL exceptions and do not create receipts. PostgREST wraps these as error objects;
clients should use `code`/`message`, not rely on an HTTP success for conflicts.

### Explicit handicap import

Only `handicap_round` may supply `payload.sourceSavedRoundID`. Omitted or JSON
null means no link. Otherwise it must be a UUID string. An extracted UUID column
enforces one `(user_id, sourceSavedRoundID)` across handicap rows, **including
tombstones**. A duplicate returns a durable `source_conflict` with the existing
linked row. Only the exact key/casing is recognized. Editing/removing a source link
is allowed by a matching CAS put; uniqueness applies to the currently stored link,
not all historical links. If permanent provenance is required, add a reviewed
constraint before client integration.

The link is an opaque reference within that user's namespace, not a foreign key
requiring a live saved round. Out-of-order sync and preserved HCP history after
saved-round deletion are supported. It never reveals another UID's records. No
automatic HCP import, score calculation, eligibility determination, or cascading
saved-round deletion exists. With the domain-validation migration installed,
custom-course and custom-tee parent links must reference matching active records
owned by the same account; they are not SQL foreign keys, so soft deletion still
requires the client to delete children first. Other unapproved record kinds are
rejected until a later DTO/migration explicitly adds them.

## Changes / bootstrap

First request (all defaults shown):

```json
{ "p_after": "0", "p_through": null, "p_limit": 100 }
```

Exact response shape:

```json
{
  "events": [],
  "next_after": "0",
  "through": "0",
  "has_more": false
}
```

Each nonempty `events` element has exactly `sequence: STRING` and `record: RECORD`.
Events are complete immutable snapshots, including tombstones. Page size 1–200,
default 100. Rows are ascending, exclusive of `after`, inclusive of `through`.
Omit/null `through` only at the start of a new window: the server captures the
committed per-user high-water mark. Continue with returned `next_after` AND the
same `through`. Concurrent writes cannot change the bounded result set. On
`has_more=false`, durable cursor becomes `through`; start next window with null
`through`. Reject future/negative/inverted cursors. Cursor is not a credential and
does not carry UID; the client must namespace it to account and protocol version.

Bootstrap replays from `"0"` into an empty account-scoped cache, applying only the
latest revision per UUID and keeping tombstones from resurrecting records. This
is historical replay, not a separate current-state snapshot endpoint. Persist
each page and cursor atomically or replay safely. A success receipt can be older
than already-pulled state; never regress a local revision. Deleted/current payloads
and all events/receipts are retained indefinitely in phase 1. There is no pruning,
retention watermark, compaction, or expired-cursor recovery protocol yet.

## Error and lifecycle semantics

- `28000 authentication_required`: missing UID (RPC execute itself is denied to anon).
- `42501 account_not_active`: blocked/deleting account; no read/replay/new mutation.
- `22023`: invalid request/cursor/source key/delete payload or changed mutation reuse.
- `22003`: decimal value exceeds bigint range (including exhausted sequence).
- `23503`: auth identity missing; stale JWT cannot create a new account row.
- `40001`/`40P01`: retry whole transaction with identical mutation ID/request.
- Storage/constraint/transport failures: do not mark synced; retry safely.

The lazy account insert requires an extant `auth.users` UID. The forward-only
`202610210001_account_deletion.sql` migration adds the authenticated
`pintheory_begin_account_deletion()` RPC and the
`supabase/functions/delete-account` Edge Function. The begin RPC locks the same
account row as mutations and requires JWT `iat` within the preceding 10 minutes
only for `active` -> `deleting`; an already-deleting state is idempotent without
a fresh `iat`. Pulls hold a shared row lock through their read, so transition and
purge serialize with in-flight sync RPCs. Once the transition commits, sync reads
and writes fail closed.

The private `pintheory_sync.purge_account_data(uuid)` function requires
`auth.role() = 'service_role'`, a matching account in `deleting` state, and locks
that account row. It removes records, events and receipts while retaining the
deleting account row. Immutable-history triggers permit only DELETE when a
transaction-local `pintheory.purge_uid` matches `OLD.user_id` and `current_user`
is the fixed `postgres` function owner. The schema remains unexposed; the narrow
`public.pintheory_purge_account(uuid)` PostgREST bridge is executable only by
`service_role` and invokes that private function as `postgres`.

The Edge Function verifies the caller's access token, invokes the begin RPC with
that user JWT, calls the service-role purge bridge, then deletes the Auth identity.
Deploy the base migration first, then the deletion migration, then the function.
Its server-side environment requires `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and
`SUPABASE_SERVICE_ROLE_KEY`; optional `CORS_ALLOWED_ORIGIN` permits one exact
browser origin. Do not put the service-role key in the app. HTTP 200 means the
source workflow completed; a 503 means deletion remains pending and the account
must stay blocked while a still-valid session retries.

Provider-grant revocation, backup erasure/retention, client local-data clearing,
and recovery if Auth deletion succeeds but its response is lost are not solved by
this source workflow. Read requests already in flight before the transition can
finish; there is no retroactive response revocation.
