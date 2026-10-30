# Catalog search integration notes

The `/api/v1/catalog/clubs` route serves pages from the currently active
`pintheory_catalog` import. It is authenticated and uncached (`Cache-Control:
no-store`); the Edge calls only `pintheory_catalog_search`, never the GolfAPI claim,
provider, or response-cache path. The SQL applies Auth/sync account gates and a
separate per-user daily search cap. The iOS client keeps result pages in memory,
clears legacy persisted search responses on live initialization, and retains
separately cached selected detail/coordinates/tee-specific geometry under the
signed-in account's local directory. That local provider-course cache is an LRU
of at most five course IDs per account; choosing a sixth evicts the least recently
used local detail, coordinates, geometry and terrain folder. The Supabase shared
provider response cache is server-side shared cache, not a per-user saved course.
Search matches a contiguous phrase in the club name only, ignoring letter case.
Course names do not create search hits; after a club is selected, its course
summaries are shown for course selection.

The operator confirmed the GolfAPI agreement permits serving a user-selected
subset to signed-in golf-app users; do not expose a bulk-catalog export route.

Before deployment, apply catalog migrations through
`202610300005_catalog_club_name_only_search.sql` in disposable staging and run
`tests/sql/catalog_search_regression.sql` plus the full Edge tests. The
production data is already imported. The forward migration updates matching
behavior while preserving service-only access controls.
