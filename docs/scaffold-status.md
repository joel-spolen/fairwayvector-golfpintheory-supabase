# Scaffold completion — 2026-10-24

## Included source

- Four historical account migrations with original IDs: sync foundation,
  account deletion, strict sync-domain validation, and service-only account metrics.
- Five original account SQL regression scripts, including the explicitly manual
  independent-session concurrency procedure.
- Original delete-account Edge handler and complete sync wire contract.
- Existing shared-data-cache forward migration, cache SQL regression, golf-data
  Edge handler, shared modules and injected-transport tests, retained in place.
- Redacted public Auth setup, CLI configuration, placeholder-only environment
  example, ignore rules, source provenance, testing and deployment runbooks.
- Pull-request/main source-check CI and a separate manual staging/production
  deployment workflow. Neither source checks nor merging a PR authorizes deployment.

## Fidelity

All eleven imports match the actual sibling originals after splitting UTF-8 text
on CRLF/LF, applying `trimEnd()` to each line, joining with LF and trimming final
whitespace. Policy: **content copied; whitespace normalized**. Leading indentation,
internal spacing, interior blank lines and all non-whitespace content are checked.
The copied domain-validation SQL indentation was restored to match its original.
Original source-byte fingerprints remain capture metadata; normalized fingerprints
are the active copy-fidelity gate. See [provenance](source-provenance.md).

## Executed checks in this checkout

| Check                                                                                                                                                    | Result                                                                                     |
| -------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Edge suite alone, `node --test tests/edge.test.js`                                                                                                       | 25 passed, 0 failed; offline injected transports, including uncertain-dispatch regressions |
| Final `npm test` (Edge + provenance)                                                                                                                     | 39 total: 38 passed, 0 failed, 1 optional sibling-comparison skip                          |
| Final `npm test` with `LEGACY_SOURCE_ROOT` selecting the sibling originals                                                                               | 39 passed, 0 failed, 0 skipped                                                             |
| `node --test tests/provenance.test.js` with `LEGACY_SOURCE_ROOT` selecting the sibling originals                                                         | 14 passed, 0 failed, 0 skipped; all eleven imports compared                                |
| `npm exec --offline --yes --package=deno@2 -- deno check --cached-only supabase/functions/golf-data/index.ts supabase/functions/delete-account/index.ts` | Exit 0; both entry points checked with cached Deno 2.9.6                                   |
| Local admin server `npm run check` / `npm test`                                                                                                          | Exit 0 / 27 total: 26 passed, 0 failed, 1 opt-in SQL integration skip                      |
| Both workflow YAML files parsed, with secret-scope/manual-trigger assertions                                                                             | Exit 0; not a GitHub Actions execution                                                     |
| Supabase CLI `2.122.0` version and `link`, `db push`, `functions deploy` help                                                                            | All exit 0; workflow flags present; no operational command invoked                         |

The system had no standalone `deno` executable. Final checks used the cached
Deno 2.9.6 package through npm's offline mode and Deno's `--cached-only` flag;
earlier initial public package resolution downloaded dependencies. Explicit
`nodeModulesDir: "none"` fixes npm-import resolution beside the Node package
manifest by using Deno's global cache, without a local dependency install.
The deletion SDK resolution was confirmed by `deno info --json` as
`@supabase/supabase-js@2.118.0`, also present in the global package cache. Its
original `@2` range and disabled lock policy still need review/pinning before
production. The SDK import was not changed, preserving source provenance.

The global Supabase CLI was 2.121.0; the exact 2.122.0 package was downloaded
from the public registry and its version/help checked from a temporary directory.
This tool download was separate from the offline test runs. Deployment secrets
are now step-scoped and the workflow selects CLI 2.122.0. Action version tags and
Deno `v2.x` remain mutable, not production-grade immutable pins.

The iOS repository's tracked `git diff --binary HEAD -- .` SHA-256 was identical
at the start and end of this validation:
`509d3e9212ed90c5d5226f82fc9b77deb1b85ed1474409f4bb8ac798eeb8702e`.
This proves no tracked-diff change during this turn, not absence of earlier edits
or changes to untracked files. No pre-consolidation/all-agent baseline is asserted.

These results establish source checks, **not SQL correctness or hosted acceptance**.
The copied deletion handler is type-checked, not covered by the golf-data transport
suite. Full-schema SQL, independent-session races, real Auth/JWT gateways,
deletion/retry behavior, backup/restore, licensing/spend controls and protected
GitHub Environment approvals remain release gates in [testing](testing.md) and
[deployment](deployment.md). CI has been reviewed as source, not executed on GitHub.

## Scope and remote state

All source edits use patches. Temporary scaffold-verification task entries are
removed after validation; the parent configuration retains its original empty
task array and no server task configuration was created.
No iOS or local-admin-server files are edited. No git
initialization, commit, remote configuration, push, hosted project link, remote
migration, function deployment, Auth dashboard change or paid-provider request is
performed by this completion. Provider settings remain disabled by default;
iOS routing and the localhost admin server remain separate, unchanged work.

This status does not assert that external projects or pre-existing deployments
are absent; no hosted state was queried. Private operations/recovery material,
exports and actual credentials are not part of the scaffold. Original files stay
in the sibling repository; nothing is moved or removed there.
