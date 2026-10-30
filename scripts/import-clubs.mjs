import { createHash, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createPrompter } from './cache-sweden-clubs.mjs';
import { validateDirectory } from './validate-clubs.mjs';

const EXPECTED_CLUBS = 30062;
const EXPECTED_COURSES = 44559;
const PAGE_SIZE = 200;
const MAX_CHUNK_CLUBS = 100;
const MAX_CHUNK_BYTES = 450000;
const root = fileURLToPath(new URL('../', import.meta.url));
const fail = message => { throw new Error(message); };
const sha256 = value => createHash('sha256').update(value).digest('hex');
const sqlText = value => `'${String(value).replaceAll("'", "''")}'`;

function splitChunks(clubs) {
  const chunks = [];
  let current = [];
  let courseCount = 0;
  for (const club of clubs) {
    const candidate = [...current, club];
    const encoded = JSON.stringify(candidate);
    if (Buffer.byteLength(encoded) > MAX_CHUNK_BYTES) {
      if (!current.length) fail('One club record exceeds the safe chunk size; import stopped before any database writes.');
      chunks.push({ clubs: current, courseCount,
        sha256: sha256(JSON.stringify(current)) });
      current = [club];
      courseCount = club.courses.length;
      if (Buffer.byteLength(JSON.stringify(current)) > MAX_CHUNK_BYTES) {
        fail('One club record exceeds the safe chunk size; import stopped before any database writes.');
      }
    } else {
      current = candidate;
      courseCount += club.courses.length;
    }
    if (current.length === MAX_CHUNK_CLUBS) {
      chunks.push({ clubs: current, courseCount, sha256: sha256(JSON.stringify(current)) });
      current = [];
      courseCount = 0;
    }
  }
  if (current.length) chunks.push({ clubs: current, courseCount, sha256: sha256(JSON.stringify(current)) });
  return chunks;
}

export async function buildImportPlan(directory, { expectedClubs = EXPECTED_CLUBS,
  expectedCourses = EXPECTED_COURSES } = {}) {
  const validated = await validateDirectory(directory, expectedClubs, expectedCourses, { collect: true });
  const names = await readdir(directory);
  const pageFiles = names.filter(name => /^page-\d+\.json$/.test(name)).sort((a, b) =>
    Number(/\d+/.exec(a)[0]) - Number(/\d+/.exec(b)[0]));
  const pageHashes = [];
  for (let i = 0; i < pageFiles.length; i++) {
    const raw = await readFile(join(directory, pageFiles[i]));
    pageHashes.push({ page: i + 1, sha256: sha256(raw) });
  }
  const chunks = splitChunks(validated.data);
  const sourceManifest = { provider: 'golfapi', kind: 'clubs-with-course-summaries',
    clubs: validated.clubs, courses: validated.nestedCourseSummaries, pageHashes };
  const sourceSha256 = sha256(JSON.stringify(sourceManifest));
  return { importId: sourceSha256, sourceSha256,
    datasetVersion: `golfapi-clubs-${sourceSha256.slice(0, 20)}`,
    clubs: validated.clubs, courses: validated.nestedCourseSummaries,
    pages: validated.pages, chunks };
}

function guardedQuery(sql) {
  const claims = JSON.stringify({ role: 'service_role' });
  return `begin;\n` +
    `select pg_catalog.set_config('request.jwt.claim.role','service_role',true);\n` +
    `select pg_catalog.set_config('request.jwt.claims',${sqlText(claims)},true);\n` +
    `${sql}\n` +
    `commit;\n`;
}

export function safeCliFailure(error) {
  const output = `${error?.stderr ?? ''}\n${error?.stdout ?? ''}`;
  if (error?.code === 'ENOENT') return 'could not find the Supabase CLI on PATH';
  if (/not logged in|login required|access token.*(missing|invalid|expired)|failed to retrieve access token/i.test(output)) {
    return 'Supabase CLI login is missing or expired; run `supabase login` in this terminal';
  }
  if (/service_role_required|authentication_required/i.test(output)) {
    return 'the database rejected the import RPC authorization; stop and report this category';
  }
  if (/pintheory_catalog_import_.*does not exist|function .*does not exist/i.test(output)) {
    return 'the import RPC is missing on the selected project; verify migration 202610300001';
  }
  if (/permission denied|not authorized|project .*not found|invalid project ref/i.test(output)) {
    return 'the CLI account cannot access the specified project; verify account access and project reference';
  }
  if (/timed? ?out|timeout|econnreset|socket hang up|connection closed/i.test(output)
      || ['ETIMEDOUT', 'ECONNRESET', 'EPIPE'].includes(error?.code)) {
    return 'the CLI connection ended unexpectedly; check import status before retrying';
  }
  const status = Number.isInteger(error?.status) ? ` (exit ${error.status})` : '';
  return `the Supabase CLI query failed${status}; inspect read-only import status before retrying`;
}

/** Executes one bounded SQL file per RPC. The operator's authenticated CLI session is used. */
export async function uploadImportPlan({ plan, projectRef, directory, execute }) {
  if (!/^[a-z0-9]{20}$/.test(projectRef)) fail('An explicit Supabase project reference is required.');
  if (typeof execute !== 'function') fail('A database query executor is required.');
  const sqlPath = join(directory, `.catalog-import-${randomUUID()}.sql`);
  const call = async sql => {
    await writeFile(sqlPath, guardedQuery(sql), { mode: 0o600, flag: 'wx' });
    try { await execute(sqlPath, projectRef); }
    catch (error) {
      fail(`Supabase import step failed: ${safeCliFailure(error)}. No automatic retry was made; chunk writes are idempotent.`);
    }
    finally { await rm(sqlPath, { force: true }); }
  };
  await call(`select public.pintheory_catalog_import_begin(${[
    sqlText(plan.importId), sqlText(plan.sourceSha256), sqlText(plan.datasetVersion),
    plan.clubs, plan.courses, plan.chunks.length
  ].join(',')});`);
  for (let i = 0; i < plan.chunks.length; i++) {
    const chunk = plan.chunks[i];
    const payload = JSON.stringify(chunk.clubs);
    if (Buffer.byteLength(payload) > MAX_CHUNK_BYTES) fail(`Chunk ${i + 1} exceeds safe request size.`);
    await call(`select public.pintheory_catalog_import_chunk(${[
      sqlText(plan.importId), i + 1, sqlText(chunk.sha256), `${sqlText(payload)}::jsonb`, chunk.courseCount
    ].join(',')});`);
  }
  await call(`select public.pintheory_catalog_import_finalize(${sqlText(plan.importId)});`);
  return { clubs: plan.clubs, courses: plan.courses, chunks: plan.chunks.length };
}

function cliExecutor(sqlPath, projectRef) {
  execFileSync('supabase', ['db', 'query', '--linked', '--project-ref', projectRef,
    '--output', 'json', '--file', sqlPath], {
    cwd: root, encoding: 'utf8', maxBuffer: 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'], timeout: 120000
  });
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length !== 4 || args[0] !== '--project-ref' || args[2] !== '--directory'
      || !/^[a-z0-9]{20}$/.test(args[1])) {
    fail('Usage: node scripts/import-clubs.mjs --project-ref <ref> --directory <validated-page-folder>');
  }
  const projectRef = args[1];
  const directory = resolve(args[3]);
  const plan = await buildImportPlan(directory);
  console.log(`Validated source: ${plan.clubs} clubs, ${plan.courses} course summaries, ${plan.pages} pages.`);
  console.log(`Private Supabase destination: ${projectRef}; ${plan.chunks.length} bounded chunks.`);
  console.log('This uploads privately through service-role-only RPCs; it does not enable app reads/search or contact GolfAPI.');
  console.log('Supabase CLI must already be logged in and migration 202610300001 must already be applied to this exact project.');
  if (!process.stdin.isTTY) fail('Interactive confirmation required; no Supabase writes were made.');
  const prompter = createPrompter();
  try {
    const answer = await prompter.prompt('Type IMPORT to upload the complete directory to Supabase: ');
    if (answer !== 'IMPORT') fail('Confirmation not received. No Supabase writes were made.');
  } finally { prompter.close(); }
  const result = await uploadImportPlan({ plan, projectRef, directory, execute: cliExecutor });
  console.log(`Private import complete: ${result.clubs} clubs and ${result.courses} course summaries in ${result.chunks} chunks.`);
  console.log('No catalogue search/read endpoint was enabled.');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
