# Populate Sweden club-search cache

Run the sibling Node helper interactively with `--project-ref` and the intended
hosted project reference. This is an explicitly authorized live operation, not a
migration. It requires a public publishable/anon project key and a signed-in,
nonanonymous app user (email/password or existing user access token). Enter all
credentials directly in the terminal's hidden prompts, never in chat, source,
command arguments or logs. It does not need provider/service-role keys.

The helper sequentially calls the existing authenticated `golf-data` route with
`country=Sweden&page=1`, then pages 2 and 3 only as needed. Existing pages are
cache hits; misses use the deployed claim/provider/finish path with existing
account gates, budgets, cooldowns and uncertain-job fences. Maximum three search
requests / three new provider sends (0.3 provider credits at documented pricing),
with no retries. No details, coordinates, settings changes or deployments.

On HTTP/transport/validation failure it stops. Do not blindly rerun an uncertain
attempt; inspect the hosted jobs/cache first. Success requires an acknowledged
HIT/MISS, consistent `numAllClubs`, expected page sizes and unique club IDs across
pages. More than 600 clubs yields an explicitly incomplete result, never a fourth
request. Sequential pages cannot guarantee a transactional provider snapshot.
Only summary counts/cache statuses are printed; no dataset export is written.

The current app/backend still use exact search keys. Populating these pages does
**not** yet make a named search filter the country directory or make the iOS app
load subsequent pages. That integration is a separate code change. A complete
directory must not be inferred from a single 200-club response.
