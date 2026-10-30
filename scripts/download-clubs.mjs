import { mkdir, open, readFile, rename, unlink } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createPrompter } from './cache-sweden-clubs.mjs';

const EXPECTED_TOTAL = 30062;
const PAGE_SIZE = 200;
const fail = message => { throw new Error(message); };
const integer = value => typeof value === 'number' && Number.isSafeInteger(value) ? value
  : typeof value === 'string' && /^\d+$/.test(value) && Number.isSafeInteger(Number(value)) ? Number(value) : NaN;

async function readOptional(path) {
  try { return await readFile(path, 'utf8'); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

async function exclusiveWrite(path, text) {
  const file = await open(path, 'wx', 0o600);
  try { await file.writeFile(text); await file.sync(); }
  finally { await file.close(); }
}

function validate(body, page, total, seen) {
  const expected = Math.min(PAGE_SIZE, total - (page - 1) * PAGE_SIZE);
  if (!body || !Array.isArray(body.clubs) || integer(body.numAllClubs) !== total
      || integer(body.numClubs) !== body.clubs.length || body.clubs.length !== expected) {
    fail(`Page ${page}: unexpected count/total. Response preserved; stopped without retry.`);
  }
  for (const club of body.clubs) {
    // Provider IDs are opaque: never round large numeric IDs or normalize strings.
    const id = typeof club?.clubID === 'string' && club.clubID.length ? club.clubID
      : Number.isSafeInteger(club?.clubID) ? String(club.clubID) : null;
    if (!id || seen.has(id) || typeof club.clubName !== 'string' || !club.clubName
        || !Array.isArray(club.courses)) {
      fail(`Page ${page}: missing/duplicate club ID or malformed club. Response preserved; stopped.`);
    }
    seen.add(id);
  }
}

export async function downloadClubs({ directory, getKey, fetchImpl = fetch, log = console.log, total = EXPECTED_TOTAL }) {
  if (!Number.isSafeInteger(total) || total < 1 || total > EXPECTED_TOTAL) fail('Invalid download limit.');
  const pages = Math.ceil(total / PAGE_SIZE);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const lock = join(directory, '.download.lock');
  try { await exclusiveWrite(lock, 'One downloader at a time. If interrupted, confirm it is stopped before removing this lock.\n'); }
  catch (error) {
    if (error.code === 'EEXIST') fail('Download lock exists. Stop any other downloader before inspecting/removing the lock.');
    throw error;
  }
  let requests = 0;
  let apiKey;
  const seen = new Set();
  try {
    for (let page = 1; page <= pages; page++) {
      const path = join(directory, `page-${page}.json`);
      const attempt = join(directory, `page-${page}.attempt`);
      let text = await readOptional(path);
      const saved = text !== null;
      if (!saved) {
        if (await readOptional(attempt) !== null) {
          fail(`Page ${page}: previous attempt is uncertain. Inspect its attempt/response files before authorizing a retry.`);
        }
        apiKey ??= await getKey();
        if (typeof apiKey !== 'string' || !apiKey.trim() || /[\r\n]/.test(apiKey)) fail('GolfAPI key required.');
        // Fence the paid send on disk BEFORE network I/O. A crash/error never
        // silently causes the next run to repeat that uncertain paid request.
        await exclusiveWrite(attempt, JSON.stringify({ page, startedAt: new Date().toISOString(),
          url: `https://golfapi.io/api/v2.3/clubs?page=${page}` }));
        let response;
        try {
          requests++;
          response = await fetchImpl(`https://golfapi.io/api/v2.3/clubs?page=${page}`, {
            headers: { Authorization: `Bearer ${apiKey}`, Accept: 'application/json' },
            redirect: 'error', signal: AbortSignal.timeout(60000)
          });
          text = await response.text();
          // Retain every completed response before inspecting it, even errors.
          await exclusiveWrite(`${path}.response`, text);
        } catch {
          fail(`Page ${page}: request/storage outcome uncertain. Attempt marker retained; no retry made.`);
        }
        if (!response.ok) fail(`Page ${page}: HTTP ${response.status}. Response saved; no retry made.`);
      }
      let body;
      try { body = JSON.parse(text); }
      catch { fail(`Page ${page}: invalid JSON. Saved response retained; no retry made.`); }
      validate(body, page, total, seen);
      if (!saved) {
        // Only validated responses become reusable pages. Redact stale credit
        // balances while preserving all club and nested course summary fields.
        const { apiRequestsLeft, ...data } = body;
        await exclusiveWrite(`${path}.validated`, JSON.stringify(data));
        await rename(`${path}.validated`, path);
        await unlink(`${path}.response`);
        await unlink(attempt);
      }
      log(`Page ${page}/${pages}: ${body.clubs.length} clubs (${saved ? 'saved page reused' : 'downloaded'}); ${seen.size}/${total} unique clubs.`);
    }
    if (seen.size !== total) fail('Incomplete directory.');
    log(`Complete: ${seen.size} clubs across ${pages} local pages; ${requests} new requests. Nothing uploaded to Supabase.`);
    return { clubs: seen.size, pages, requests };
  } finally { await unlink(lock); }
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length !== 2 || args[0] !== '--directory') fail('Usage: node scripts/download-clubs.mjs --directory <saved-page-folder>');
  const directory = resolve(args[1]);
  console.log(`Download destination: ${directory}`);
  console.log('Worldwide clubs only. Target: 30,062 unique clubs / 151 pages. Existing valid pages are reused.');
  console.log('Maximum 151 new requests (15.1 provider credits), no retries, no details/GPS, no Supabase writes.');
  const prompter = process.stdin.isTTY ? createPrompter() : null;
  try {
    await downloadClubs({ directory, getKey: async () => {
      if (!prompter) fail('Run in an interactive terminal to enter the GolfAPI key securely.');
      const key = await prompter.prompt('Paste GolfAPI key, then press Return (hidden): ', true);
      prompter.close();
      return key;
    } });
  } finally { prompter?.close(); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}