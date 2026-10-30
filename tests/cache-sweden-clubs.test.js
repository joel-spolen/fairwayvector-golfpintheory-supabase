import test from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';
import { cacheSwedenClubs, createPrompter } from '../scripts/cache-sweden-clubs.mjs';

test('hidden input advances to visible next prompt and restores terminal mode', async () => {
  const input = new PassThrough();
  input.setRawMode = value => { input.isRaw = value; };
  const chunks = [];
  const prompter = createPrompter(input, { write: text => chunks.push(text) });
  const key = prompter.prompt('Public key: ', true);
  input.write('dummy-key\r');
  assert.equal(await key, 'dummy-key');
  assert.equal(input.isRaw, false);
  const method = prompter.prompt('Choose email/token: ');
  input.write('email\r');
  assert.equal(await method, 'email');
  const password = prompter.prompt('Password: ', true);
  input.write('dummy-secret\r');
  assert.equal(await password, 'dummy-secret');
  prompter.close();
  const output = chunks.join('');
  assert.ok(output.includes('Input received.\nChoose email/token: '));
  assert.ok(output.includes('Password: '));
  assert.ok(!output.includes('dummy-key') && !output.includes('dummy-secret'));
  assert.equal(input.isRaw, false);
  assert.equal(input.listenerCount('keypress'), 0);
});

test('cancelling hidden input rejects and restores terminal mode', async () => {
  const input = new PassThrough();
  input.setRawMode = value => { input.isRaw = value; };
  const prompter = createPrompter(input, { write() {} });
  const answer = prompter.prompt('Secret: ', true);
  input.write('\x03');
  await assert.rejects(answer, /Cancelled/);
  assert.equal(input.isRaw, false);
  prompter.close();
});

const options = { projectRef: 'abcdefghijklmnopqrst', publicKey: 'public-fixture', accessToken: 'user-fixture', log() {} };
const pageResponse = (page, total, cache = 'MISS') => new Response(JSON.stringify({ numAllClubs: total,
  clubs: Array.from({ length: Math.min(200, Math.max(0, total - (page - 1) * 200)) },
    (_, i) => ({ clubID: `${(page - 1) * 200 + i}`, clubName: 'Fixture' }))
}), { headers: { 'x-cache': cache } });

test('three sequential exact Sweden page requests populate 500 clubs; no extra confirmation calls', async () => {
  const urls = [];
  const result = await cacheSwedenClubs({ ...options, fetchImpl: async (url, init) => {
    urls.push(url);
    assert.equal(init.redirect, 'error');
    assert.equal(init.headers.Authorization, 'Bearer user-fixture');
    return pageResponse(urls.length, 500, urls.length === 1 ? 'HIT' : 'MISS');
  } });
  assert.deepEqual(urls, [1, 2, 3].map(p =>
    `https://abcdefghijklmnopqrst.supabase.co/functions/v1/golf-data/api/v1/golf/clubs?country=Sweden&page=${p}`));
  assert.deepEqual(result, { complete: true, total: 500, fetched: 2, pages: 3 });
});

test('stops early for complete small or empty directory and never exceeds three pages', async () => {
  for (const total of [0, 125, 200, 400, 700]) {
    let calls = 0;
    const result = await cacheSwedenClubs({ ...options, fetchImpl: async () => pageResponse(++calls, total) });
    assert.equal(calls, Math.min(3, Math.max(1, Math.ceil(total / 200))));
    assert.equal(result.complete, total <= 600);
  }
});

test('HTTP, ambiguous transport, missing total and duplicate page stop without retries or later pages', async () => {
  for (const response of [() => new Response('{}', { status: 503 }),
    () => { throw new Error('sensitive transport diagnostic'); },
    () => new Response('{"clubs":[]}', { headers: { 'x-cache': 'HIT' } })]) {
    let calls = 0;
    await assert.rejects(cacheSwedenClubs({ ...options, fetchImpl: async () => { calls++; return response(); } }));
    assert.equal(calls, 1);
  }
  let calls = 0;
  await assert.rejects(cacheSwedenClubs({ ...options, fetchImpl: async () => {
    calls++; return pageResponse(1, 500);
  } }), /duplicate/);
  assert.equal(calls, 2);
});