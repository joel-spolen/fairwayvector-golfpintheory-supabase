# Catalog search integration notes

The new `/api/v1/catalog/clubs` route serves pages from the currently active
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

Changing the route does **not** make this third-party catalogue permissible to
serve to users. Verify the GolfAPI agreement permits this exact distribution to
signed-in app users. The provider's public marketing statement permits storage
but says redistribution/sharing with third parties is not permitted; in-memory
only handling does not change the license analysis. Do not deploy the Edge
function or migration until that permission has been confirmed.

Before deployment, apply `202610300002_catalog_search.sql` in disposable staging
and run `tests/sql/catalog_search_regression.sql` plus the full Edge tests. The
production data is already imported; this migration is separate and not yet
applied. Run the Edge Function deploy only after migration, license approval, and
staging validation. No hosted deployment was performed by source validation.
