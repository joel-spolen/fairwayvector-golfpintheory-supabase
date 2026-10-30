import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildImportPlan, safeCliFailure, uploadImportPlan } from '../scripts/import-clubs.mjs';

async function withDirectory(run) {
  const directory = await mkdtemp(join(tmpdir(), 'catalog-import-test-'));
  try { await run(directory); } finally { await rm(directory, { recursive: true, force: true }); }
}
function page(pageNo, total = 201) {
  const count = Math.min(200, total - (pageNo - 1) * 200);
  return { numClubs: count, numAllClubs: total, clubs: Array.from({ length: count }, (_, index) => ({
    clubID: `club-${(pageNo - 1) * 200 + index}`, clubName: 'Fixture club', country: 'Sweden',
    courses: [{ courseID: `course-${(pageNo - 1) * 200 + index}`, courseName: 'Fixture course', hasGPS: 1 }]
  })) };
}
async function writePages(directory, total = 201) {
  for (let n = 1; n <= Math.ceil(total / 200); n++) {
    await writeFile(join(directory, `page-${n}.json`), JSON.stringify(page(n, total)));
  }
}

test('builds deterministic normalized chunks and uses private idempotent RPC sequence', () => withDirectory(async directory => {
  await writePages(directory);
  const plan = await buildImportPlan(directory, { expectedClubs: 201, expectedCourses: 201 });
  assert.equal(plan.clubs, 201);
  assert.equal(plan.courses, 201);
  assert.equal(plan.chunks.length, 3);
  assert.equal(plan.chunks[0].clubs[0].clubID, 'club-0');
  assert.equal(typeof plan.chunks[0].clubs[0].courses[0].courseID, 'string');
  assert.equal((await buildImportPlan(directory, { expectedClubs: 201, expectedCourses: 201 })).importId, plan.importId);

  const sqlFiles = [];
  const result = await uploadImportPlan({ plan, projectRef: 'abcdefghijklmnopqrst', directory,
    execute: async (path, target) => {
      assert.equal(target, 'abcdefghijklmnopqrst');
      const sql = await readFile(path, 'utf8');
      assert.match(sql, /^begin;/);
      assert.match(sql, /set_config\('request\.jwt\.claim\.role','service_role',true\)/);
      assert.match(sql, /set_config\('request\.jwt\.claims'/);
      assert.match(sql, /commit;\s*$/);
      assert.match(sql, /pintheory_catalog_import_/);
      assert.doesNotMatch(sql, /golfapi\.io|coordinates\//);
      sqlFiles.push(sql);
    } });
  assert.deepEqual(result, { clubs: 201, courses: 201, chunks: 3 });
  assert.match(sqlFiles[0], /pintheory_catalog_import_begin/);
  assert.equal(sqlFiles.filter(sql => /pintheory_catalog_import_chunk/.test(sql)).length, 3);
  assert.match(sqlFiles.at(-1), /pintheory_catalog_import_finalize/);
  assert.deepEqual((await readdir(directory)).filter(name => name.endsWith('.sql')), []);
}));

test('revalidates totals before import plan and aborts on uncertain RPC without automatic retry', () => withDirectory(async directory => {
  await writePages(directory);
  await assert.rejects(buildImportPlan(directory, { expectedClubs: 201, expectedCourses: 202 }), /course summaries/);
  const plan = await buildImportPlan(directory, { expectedClubs: 201, expectedCourses: 201 });
  let calls = 0;
  await assert.rejects(uploadImportPlan({ plan, projectRef: 'abcdefghijklmnopqrst', directory,
    execute: async () => { calls++; throw new Error('redacted'); } }), /inspect read-only import status/);
  assert.equal(calls, 1);
  assert.deepEqual((await readdir(directory)).filter(name => name.endsWith('.sql')), []);
}));

test('reports safe CLI failure categories without leaking raw output', () => {
  assert.match(safeCliFailure({ code: 'ENOENT' }), /CLI on PATH/);
  assert.match(safeCliFailure({ stderr: 'not logged in\nPRIVATE_CLUB_NAME' }), /supabase login/);
  assert.match(safeCliFailure({ stderr: 'service_role_required\nPRIVATE_CLUB_NAME' }), /authorization/);
  assert.match(safeCliFailure({ stderr: 'database timeout\nPRIVATE_CLUB_NAME', status: 1 }), /status before retrying/);
  assert.doesNotMatch(safeCliFailure({ stderr: 'not logged in\nPRIVATE_CLUB_NAME' }), /PRIVATE_CLUB_NAME/);
});
