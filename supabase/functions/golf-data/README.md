# golf-data Edge function

This authenticated Edge Function is the only app route to GolfAPI/GPXZ. No provider
credential or upstream provider URL belongs in the iOS app. The repository-level
package manifest sets ESM/Node >=22 and the offline `npm test` script. No
dependencies or lockfile are needed. The parent repository owns Supabase/Deno
configuration and deployment.

## Runtime and credentials

- `index.ts` is the only Deno entry point; shared JS and `handler.js` are Web API
  modules importable by Node without Deno, Node Buffer, SDKs, or network at import.
- Platform environment: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and
  `SUPABASE_SERVICE_ROLE_KEY`. Provider secrets: `GOLF_API_KEY`, `GPXZ_API_KEY`.
  Never put provider or service keys in clients or SQL settings.
- The ignored local-only `supabase/functions/.env.local` can be supplied to
  `supabase secrets set --env-file ... --project-ref ...`. Rotate any keys that
  appeared in diagnostics before setting them. Do not commit the file or use it
  as an Xcode configuration input.
- Authentication calls the fixed project's `/auth/v1/user` online with the anon
  apikey and the supplied user bearer. It requires a UUID and explicit
  `is_anonymous: false`; it never decodes a JWT locally. Shared/admin/public keys
  are not an alternative authentication path. Missing config fails closed.
- Every valid data request invokes `pintheory_data_claim` with the verified UUID,
  including cache hits. SQL is responsible for the current Auth banned/deleted
  and sync blocked/deleting account gates and all global/per-user limits.
- Service REST calls use a fixed four-RPC allowlist. Legacy service JWT keys use
  apikey + bearer; `sb_secret_` keys use apikey only. Exactly HTTP 200 is accepted.
  Auth and RPC each have a 10-second entire-operation abort/deadline, including
  bounded streamed JSON reads. No transport retries or raw error bodies/logs.
- Every Origin header (including empty or `null`) is rejected. OPTIONS is 403;
  there is no browser CORS mode. Native callers omit Origin.

## API/cache parity

Accepted prefixes are exactly `/functions/v1/golf-data/api/v1/...` and
`/golf-data/api/v1/...`, with no trailing slash or arbitrary prefix scanning.
GET golf clubs/courses searches accept only country/state/name/page/
timestampUpdated, each at most once. Existing server schema lengths and page
syntax are enforced before trimming/NFC normalization. Empty normalized fields
are dropped, page defaults to `1`, sorted pairs produce the same SHA-256 key.
timestampUpdated probes use `p_max_age_seconds: 86400`; other requests use null.
Detail and coordinates accept only the existing strict ID syntax, no query.

POST elevation/sample accepts JSON or GPXZ-style URL-encoded form bodies, at
most 300000 streamed bytes. Top-level and point unknown fields, duplicate form
parameters, query parameters, and invalid schema/geometry/options are rejected.
The copied geometry preserves vertices, repeated-point normalization, sample
count, precision, longitude interpolation, and the exact normalized key format.
Optional courseID is metadata only, never part of the key or paid provider form.
Shared validators and provider formats are copied from the current server;
provider transport uses bounded Uint8Array + fatal TextDecoder instead of Buffer,
rejects redirects and bounds the entire request/stream to 30 seconds/4000000 bytes.
An injectable provider timeout is available only for offline tests.

## RPC handoff (parent integration)

All names/parameters match the current shared-data-cache migration:

- claim: `p_user_id`, `p_key`, `p_provider`, `p_cache_only`,
  `p_max_age_seconds` -> status/body/fetchedAt/datasetVersion or token/retryAfter.
- finish: `p_key`, `p_token`, `p_body`, `p_dataset_version`, `p_metadata`
  -> boolean. Golf metadata is `{}`; elevation contains profileLengthMeters and
  only an actually supplied courseID.
- fail: `p_key`, `p_token`, `p_provider_wide`, `p_retry_after` -> boolean.
  Only definitive provider APIErrors (`ambiguous !== true`) persist a cooldown
  of at least 300 seconds, capped at 86400. Known non-OK HTTP responses and
  validation failures after a complete decoded response are definitive.
- tag: `p_key`, `p_course_id` -> boolean, only for tagged elevation cache hits.
  A failed tag causes request failure, never provider fallback.

Intentional deviations from the local server / important integration notes:

1. Provider enabled flags are exclusively database settings (default disabled).
   `Providers.configured` describes key availability, not permission to spend.
   A missing key forces `p_cache_only: true` **before reservation**: existing hits
   still work, otherwise 503 provider_not_configured, including explicit cache-only
   misses when the corresponding key is absent. Configured explicit cache-only
   misses remain 404 cache_miss. A defensive unexpected CLAIMED on cache-only
   attempts a fenced fail but never dispatches.
2. No in-memory singleflight, wait loops, second claim, or automatic provider
   replay. SQL PENDING becomes 503 request_pending with Retry-After 2 (intentionally
   overriding SQL's 1); UNKNOWN becomes 503 ambiguous_attempt requiring operator
   resolution. Clients must not automatically override this with paid retries.
   Transport rejection, fetch/read deadlines, truncated streams, redirects,
   unread/oversized bodies, decoding/JSON failures, and unknown injected errors
   are conservative ambiguous outcomes, not ordinary cooldown failures. The
   immediate response is 503 ambiguous_attempt with operator-resolution text and
   no Retry-After. Edge calls neither fail nor finish: the job remains dispatched,
   counters/reservations remain charged (no refund), and SQL blocks redispatch
   with PENDING then UNKNOWN after lease expiry. Expiry/cooldown is not permission
   to retry; only explicit operator resolution can authorize another paid send.
3. FORBIDDEN -> 403; RATE_LIMIT -> 429; disabled/cooldown/budget -> 503. All
   responses are JSON with no-store/nosniff; errors are structured and sanitized.
4. finish false is a fencing/validation rejection (503 cache_write_rejected).
   A finish exception is potentially ambiguous (503 service_unavailable). Neither
   path invokes fail, reclaims, dispatches again, or returns the uncommitted body.
   fail persistence errors also return unavailable without another provider send.
5. Hits return the stored body directly, X-Cache HIT, stored X-Fetched-At and
   optional X-Dataset-Version. Misses return X-Cache MISS only after true finish.
   **The boolean finish RPC exposes no database timestamp**, so a miss's
   X-Fetched-At is the Edge acknowledgment time, not the exact SQL write time.
   A later hit exposes the exact persisted timestamp. No second claim is made
   just to retrieve it. Change the parent contract explicitly if exact parity on
   first-response timestamps is required.
6. Auth/RPC/provider wall deadlines bound individual operations, not Supabase's
   overall worker lifetime or CPU quota. A request can approach the 60-second SQL
   lease when auth/claim/finish are slow. Lease expiry alone is not proof a send
   failed; SQL's UNKNOWN/fencing semantics remain necessary. Test worst-case
   5000-vertex/512-sample CPU and real platform limits in disposable staging;
   offline Node tests do not establish deployment CPU viability.

No live Supabase sessions or paid APIs are exercised by the tests. Tests import
the real Web handler, real Providers and REST adapters with injected fake fetch;
they cover canonical keys/wire formats, strict validation/auth/origins, database
gates, pending coalescing, ambiguous attempts, missing-config hits, fail persistence,
late fence rejection and finish no-replay. All ambient fetch attempts fail tests.
Real gateway signing configuration, actual auth/SQL integration and Deno runtime
deployment must be validated by the parent in staging before release. Do not
disable gateway verification as a workaround without equivalent reviewed auth.
