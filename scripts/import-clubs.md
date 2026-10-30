# Import the private club-summary directory to Supabase

This import is **private storage only**. It does not expose a catalogue read or
search API to app users, change HCP/Explore/Play, request GolfAPI, or read course
details/GPS. Do not enable a user-facing endpoint until the GolfAPI agreement has
been checked for serving the directory/search results to app users.

## Preconditions

1. Confirm the provider agreement and retention policy permit this server-side
   cache. Source data is not committed.
2. Reconcile the intended project's migration history and schema, review the new
   forward-only `202610300001_private_club_catalog_import.sql`, apply it first to
   disposable staging, and run `tests/sql/catalog_import_regression.sql` there.
   Never run the rollback fixture on production.
3. Ensure Supabase CLI is logged in as an authorized project operator. The script
   makes explicit linked queries to the supplied project reference. It writes
   temporary SQL files containing each data chunk with mode 0600 into the local
   download folder, invokes the CLI, then removes each file. No service key is
   requested or stored by the script.
4. Ensure the private folder has enough disk space and is backed up as required.

## Run

From this repository, run:

`node scripts/import-clubs.mjs --project-ref <exact-project-ref> --directory <validated-download-folder>`

It revalidates the 151 local page files, 30,062 club IDs and 44,559 nested course
summaries before any database write. Review the explicit target/counts and type
`IMPORT` to continue. RPC payloads are bounded to 100 clubs and 450,000 UTF-8
bytes per chunk (whichever limit is reached first).

The import ID is deterministic from the local source page hashes. Begin/chunk/
finalize RPCs are service-role-only, and the CLI SQL sets the service claim
transaction-locally under the trusted operator connection. Identical chunks are
idempotent; conflicting replays fail. Incomplete/mismatched imports cannot
activate. Finalization checks all expected counts and duplicate club IDs, then
atomically points the **private** active-import row at that generation. Retrying
the same import is safe; no provider retry is involved.

The script reports only chunk progress and aggregate counts, never records or
provider balances. It does not automatically retry database commands. If a
command errors or the response is lost, stop; rerun the same command after
checking the CLI/project, or inspect the private import status through an
operator-reviewed SQL query. Exact chunk replay is supported. Do not change the
local files between retries; a changed manifest becomes a separate import.

No remote migration or import was executed by source validation. The project
must be explicitly selected/reconciled, and the reviewed migration must be
deployed before this script can run successfully.
