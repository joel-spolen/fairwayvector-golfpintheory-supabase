import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { downloadClubs } from '../scripts/download-clubs.mjs';

function body(page, total = 201) {
  return { numClubs: Math.min(200, total - (page - 1) * 200), numAllClubs: total, apiRequestsLeft: 'private-balance',
    clubs: Array.from({ length: Math.min(200, total - (page - 1) * 200) }, (_, i) => ({
      clubID: `large-opaque-id-${(page - 1) * 200 + i}`, clubName: 'Fixture',
      courses: [{ courseID: 'opaque-course-id', courseName: 'Fixture course' }]
    })) };
}

async function fixture(fn) {
  const directory = await mkdtemp(join(tmpdir(), 'clubs-test-'));
  try { await fn(directory); } finally { await rm(directory, { recursive: true, force: true }); }
}

test('reuses page one, downloads only missing page, stops at exact total and reopens without key/network', () => fixture(async directory => {
  await writeFile(join(directory, 'page-1.json'), JSON.stringify(body(1)));
  let calls = 0;
  const options = { directory, total: 201, getKey: async () => 'dummy', log() {}, fetchImpl: async (url, init) => {
    calls++;
    assert.equal(url, 'https://golfapi.io/api/v2.3/clubs?page=2');
    assert.equal(init.redirect, 'error');
    return Response.json(body(2));
  } };
  assert.deepEqual(await downloadClubs(options), { clubs: 201, pages: 2, requests: 1 });
  const saved = JSON.parse(await readFile(join(directory, 'page-2.json')));
  assert.equal(saved.apiRequestsLeft, undefined);
  assert.deepEqual(saved.clubs[0].courses, body(2).clubs[0].courses);
  assert.deepEqual(await downloadClubs({ ...options, getKey: () => assert.fail('No key needed') }),
    { clubs: 201, pages: 2, requests: 0 });
  assert.equal(calls, 1);
}));

test('network/HTTP/bad JSON/changed total/duplicate IDs stop and fence subsequent rerun', async () => {
  for (const response of [() => { throw new Error('private-error'); },
    () => new Response('private-error', { status: 429 }), () => new Response('not JSON'),
    () => Response.json(body(2, 202)), () => Response.json({ ...body(2), clubs: [body(1).clubs[0]] })]) {
    await fixture(async directory => {
      await writeFile(join(directory, 'page-1.json'), JSON.stringify(body(1)));
      let calls = 0;
      const options = { directory, total: 201, getKey: async () => 'dummy', log() {}, fetchImpl: async () => { calls++; return response(); } };
      await assert.rejects(downloadClubs(options));
      await assert.rejects(downloadClubs(options), /uncertain/);
      assert.equal(calls, 1);
    });
  }
});

test('corrupt local page and existing lock never trigger paid requests', () => fixture(async directory => {
  const options = { directory, total: 201, log() {}, getKey: () => assert.fail('No key'), fetchImpl: () => assert.fail('No network') };
  await writeFile(join(directory, 'page-1.json'), '{broken');
  await assert.rejects(downloadClubs(options), /invalid JSON/);
  await writeFile(join(directory, '.download.lock'), 'another process');
  await assert.rejects(downloadClubs(options), /lock exists/);
}));

test('30,062 clubs stop at page 151 with 62 on last page and no page 152', () => fixture(async directory => {
  let calls = 0;
  const result = await downloadClubs({ directory, getKey: async () => 'dummy', log() {},
    fetchImpl: async url => {
      calls++;
      assert.equal(Number(new URL(url).searchParams.get('page')), calls);
      assert.ok(calls <= 151);
      return Response.json(body(calls, 30062));
    } });
  assert.deepEqual(result, { clubs: 30062, pages: 151, requests: 151 });
  assert.equal(JSON.parse(await readFile(join(directory, 'page-151.json'))).numClubs, 62);
}));