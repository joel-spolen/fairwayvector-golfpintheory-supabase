# Download the worldwide club directory locally

Run `node scripts/download-clubs.mjs --directory <folder>` from the backend
repository. Use the same folder containing the previously downloaded
`page-1.json`, or a new folder to download from page 1. Node 22+ is required.
Use a private folder outside Git (for example the existing Downloads folder),
not a committed source directory. New directories/files use private permissions.

Enter the **GolfAPI key**, not a Supabase key, directly in the hidden terminal
prompt. No credential is accepted in command arguments or written to disk.
There is no app login or Supabase connection in this script.

- Fixed worldwide query: `/api/v2.3/clubs?page=N`, without other filters.
- Fixed expected total: 30,062 unique clubs; maximum 151 requests, sequential.
- Page 151 must contain 62 clubs; no empty-page confirmation request is needed.
- With saved page 1, only 150 new requests (15 provider credits) are needed.
- Each existing valid page is reused, including after a normal restart.
- All club fields and nested course summaries are retained. Newly saved pages
  omit the account-wide `apiRequestsLeft` balance.
- Counts, total, unique club IDs and basic club shape are validated. A changed
  provider total, duplicates, malformed response or HTTP/network error stops the
  download. No automatic retries, redirects, details or coordinates.
- Each completed HTTP response is saved before validation. Only validated pages
  are promoted to reusable page JSON. Error responses stay in `.json.response`.
- A `.attempt` marker is written before each paid send. An uncertain attempt
  blocks that page on the next run. Do not delete the marker and blindly retry:
  inspect the saved response and authorize any potentially billed retry first.
- `.download.lock` prevents simultaneous downloaders in the same folder. After a
  crash, first verify no downloader is running before manually removing the lock.

This direct provider operation does not use or change Supabase budgets, counters
or cached responses. It is an operator-controlled local download. Do not treat
it as an app-access path or as proof of a transactionally consistent worldwide
snapshot: the provider directory could change between page requests.

After completion, retain all pages for a separate validated Supabase import.
The script does not upload data or change HCP/Explore/Play search behavior.
