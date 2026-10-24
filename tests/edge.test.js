import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createHandler } from '../supabase/functions/golf-data/handler.js';
import { Providers, validateGolf, validateElevation } from '../supabase/functions/_shared/providers.js';
import { profileRequest, pointAt, distance } from '../supabase/functions/_shared/geometry.js';
import { APIError } from '../supabase/functions/_shared/errors.js';
import { createSupabase } from '../supabase/functions/_shared/supabase.js';

const UID = '24000002-0000-4000-8000-000000000001';
const TOKEN = '24000002-0000-4000-8000-000000000002';
const ROOT = 'https://edge.example.invalid/functions/v1/golf-data';
const URL_ROOT = 'https://offline-project.supabase.co';
const SECRET = 'offline-service-secret';
const FETCHED = '2026-10-24T12:00:00.123456Z';
const originalFetch = globalThis.fetch;
let unexpectedNetwork = 0;
before(() => { globalThis.fetch = () => { unexpectedNetwork++; throw new Error('No network allowed'); }; });
after(() => { globalThis.fetch = originalFetch; assert.equal(unexpectedNetwork, 0); });
const json = (body, options) => new Response(JSON.stringify(body), options);
const sha = value => createHash('sha256').update(value).digest('hex');
const course = { courseID: 'A', courseName: 'Å Links' };
const hit = body => ({ status: 'HIT', body, fetchedAt: FETCHED, datasetVersion: 'fixture-v1' });
const path = [{ lat: 57.12345678901234, lon: 12 }, { lat: 57.12355678901234, lon: 12.0001 }];
const sample = { path, samples: 3 };
const request = (suffix = '/api/v1/golf/courses/A', options = {}) => new Request(`${ROOT}${suffix}`, {
  ...options, headers: { Authorization: 'Bearer offline-user', ...options.headers }
});
const post = (body = sample, headers = {}) => request('/api/v1/elevation/sample', {
  method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body)
});
function fixture({ claim = hit(course), rpcImpl, authenticate, providers: overrides = {} } = {}) {
  const calls = [];
  const sends = [];
  const authentications = [];
  const providers = { configured: { golf: true, gpxz: true },
    async golf(...args) { sends.push(['golf', ...args]); return { body: course, datasetVersion: 'v1' }; },
    async elevation(...args) { sends.push(['gpxz', ...args]); return { body: elevation(args[0]), datasetVersion: 'gpxz-v1' }; },
    ...overrides };
  const handler = createHandler({ providers,
    authenticate: async token => { authentications.push(token); return authenticate ? authenticate(token) : { id: UID }; },
    rpc: async (name, args) => {
      calls.push([name, args]);
      return rpcImpl ? rpcImpl(name, args) : name === 'pintheory_data_claim' ? claim : true;
    } });
  return { handler, calls, sends, authentications };
}
function elevation(profile) {
  return { status: 'OK', results: Array.from({ length: profile.samples }, (_, i) => ({
    ...pointAt(profile, profile.length * i / (profile.samples - 1)), elevation: 123.456,
    resolution: 2, data_source: 'fixture'
  })) };
}
async function errorCode(response, expectedStatus, code) {
  assert.equal(response.status, expectedStatus);
  assert.equal((await response.json()).error.code, code);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('access-control-allow-origin'), null);
}

test('verified identity required before any claim; no shared/public bearer fallback', async () => {
  for (const authorization of ['', 'Basic offline-user', 'Bearer a,b', 'Bearer a b']) {
    const f = fixture();
    await errorCode(await f.handler(request(undefined, { headers: { Authorization: authorization } })), 401, 'unauthorized');
    assert.equal(f.calls.length, 0); assert.equal(f.authentications.length, 0);
  }
  for (const user of [null, {}, { id: 'not-uuid' }]) {
    const f = fixture({ authenticate: async () => user });
    await errorCode(await f.handler(request()), 401, 'unauthorized'); assert.equal(f.calls.length, 0);
  }
  const f = fixture({ authenticate: async () => { throw new Error(`${SECRET} private JWT`); } });
  const res = await f.handler(request());
  assert.equal(res.status, 503); assert.ok(!(await res.text()).includes(SECRET));
  assert.equal(f.calls.length, 0);
});

test('all Origin headers and OPTIONS fail closed, native requests work', async () => {
  for (const headers of [{ Origin: 'https://example.com' }, { Origin: 'null' }, { Origin: '' }]) {
    const f = fixture();
    await errorCode(await f.handler(request(undefined, { headers })), 403, 'origin_forbidden');
    assert.equal(f.authentications.length, 0); assert.equal(f.calls.length, 0);
  }
  await errorCode(await fixture().handler(request(undefined, { method: 'OPTIONS' })), 403, 'origin_forbidden');
  assert.equal((await fixture().handler(request())).status, 200);
});

test('anchored complete prefixes, strict IDs, structured method and route errors', async () => {
  for (const prefix of ['/functions/v1/golf-data', '/golf-data']) {
    const f = fixture();
    assert.equal((await f.handler(new Request(`https://example.invalid${prefix}/api/v1/golf/courses/A`,
      { headers: { Authorization: 'Bearer user' } }))).status, 200);
  }
  for (const suffix of ['/api/v1/golf/courses/A/extra', '/api/v1/golf/courses/A%2FB',
    '/api/v1/golf/courses/%41', '/api/v1/golf/coordinates/', '/api/v1/golf/courses/A/',
    '/api/v1/golf/courses/' + 'a'.repeat(101), '/admin', '/api/v1/golf/clubs/A']) {
    const f = fixture(); await errorCode(await f.handler(request(suffix)), 404, 'not_found');
    assert.equal(f.calls.length, 0);
  }
  const f = fixture();
  await errorCode(await f.handler(new Request(`https://example.invalid/other${new URL(request().url).pathname}`,
    { headers: { Authorization: 'Bearer user' } })), 404, 'not_found');
  for (const method of ['HEAD', 'PUT', 'DELETE', 'POST']) {
    await errorCode(await f.handler(request(undefined, { method })), 405, 'method_not_allowed');
  }
  await errorCode(await f.handler(request('/api/v1/elevation/sample')), 405, 'method_not_allowed');
});

test('search NFC/trim, sorted canonical key, page default and update age match server', async () => {
  const f = fixture({ claim: { status: 'CLAIMED', token: TOKEN } });
  const res = await f.handler(request('/api/v1/golf/clubs?state=%20%20&name=%20A%CC%8A%20&country=SE&timestampUpdated=123'));
  assert.equal(res.status, 200);
  const query = { name: 'Å', country: 'SE', timestampUpdated: '123', page: '1' };
  const canonical = Object.keys(query).sort().map(k => [k, query[k]]);
  assert.deepEqual(f.calls[0], ['pintheory_data_claim', { p_user_id: UID,
    p_key: `golf:v1:clubs:${sha(JSON.stringify(canonical))}`, p_provider: 'golf',
    p_cache_only: false, p_max_age_seconds: 86400 }]);
  assert.deepEqual(f.sends[0], ['golf', '/clubs', query, 'clubs']);
  const a = fixture(); const b = fixture();
  await a.handler(request('/api/v1/golf/courses?name=A%CC%8A'));
  await b.handler(request('/api/v1/golf/courses?page=1&name=%20%C3%85%20'));
  assert.equal(a.calls[0][1].p_key, b.calls[0][1].p_key);
  assert.equal(a.calls[0][1].p_max_age_seconds, null);
  // AJV maxLength counts Unicode codepoints, not UTF-16 code units.
  assert.equal((await fixture().handler(request('/api/v1/golf/clubs?name=' + encodeURIComponent('⛳'.repeat(200))))).status, 200);
  assert.equal((await fixture().handler(request('/api/v1/golf/clubs?name=' + encodeURIComponent('🏌'.repeat(200))))).status, 200);
});

test('search schema rejects duplicate/unknown params, oversized text, invalid pages and empty filters', async () => {
  for (const query of ['name=A&name=B', 'name=A&name=A', 'name=A&page=1&page=1',
    'name=A&url=https://evil.invalid', 'country=' + 'x'.repeat(121), 'state=' + 'x'.repeat(121),
    'name=' + 'x'.repeat(201), 'name=A&timestampUpdated=' + 'x'.repeat(101),
    'name=A&page=0', 'name=A&page=01', 'name=A&page=10000', 'name=A&page=%201', 'name=A&page=',
    'country=%20&state=%20', 'timestampUpdated=123']) {
    const f = fixture(); assert.equal((await f.handler(request(`/api/v1/golf/clubs?${query}`))).status, 400);
    assert.equal(f.calls.length, 0);
  }
  const f = fixture();
  await errorCode(await f.handler(request('/api/v1/golf/courses/A?name=A')), 400, 'invalid_request');
  await errorCode(await f.handler(request('/api/v1/elevation/sample?name=A', { method: 'POST' })), 400, 'invalid_request');
});

test('detail and coordinates use exact versioned key and provider path', async () => {
  for (const [collection, kind] of [['courses', 'detail'], ['coordinates', 'coordinates']]) {
    const f = fixture({ claim: { status: 'CLAIMED', token: TOKEN } });
    assert.equal((await f.handler(request(`/api/v1/golf/${collection}/A_-9`))).status, 200);
    assert.equal(f.calls[0][1].p_key, `golf:v1:${kind}:A_-9`);
    assert.deepEqual(f.sends[0], ['golf', `/${collection}/A_-9`, {}, kind, 'A_-9']);
    assert.deepEqual(f.calls[1][1].p_metadata, {});
  }
});

test('HIT returns original body/timestamps/version, SQL account gates even hits', async () => {
  const body = { ...course, exact: 1.123456789012345, extra: ['preserved'] };
  const f = fixture({ claim: hit(body) });
  const res = await f.handler(request());
  assert.deepEqual(await res.json(), body); assert.equal(res.headers.get('x-cache'), 'HIT');
  assert.equal(res.headers.get('x-fetched-at'), FETCHED); assert.equal(res.headers.get('x-dataset-version'), 'fixture-v1');
  assert.equal(f.calls.length, 1); assert.equal(f.calls[0][1].p_user_id, UID); assert.equal(f.sends.length, 0);
  await errorCode(await fixture({ claim: { status: 'FORBIDDEN', body } }).handler(request()), 403, 'forbidden');
});

test('claim outcomes never dispatch; PENDING fixed retry=2; UNKNOWN requires operator', async () => {
  for (const [status, http, code] of [
    ['FORBIDDEN', 403, 'forbidden'], ['RATE_LIMIT', 429, 'rate_limit'],
    ['BUDGET', 503, 'daily_budget_exceeded'], ['DISABLED', 503, 'provider_disabled'],
    ['COOLDOWN', 503, 'provider_cooldown'], ['PENDING', 503, 'request_pending'],
    ['UNKNOWN', 503, 'ambiguous_attempt'], ['CACHE_MISS', 404, 'cache_miss'],
    ['INVALID', 503, 'service_unavailable']
  ]) {
    const f = fixture({ claim: { status, retryAfter: 19 } });
    const res = await f.handler(request());
    assert.equal(res.headers.get('retry-after'), ['RATE_LIMIT', 'COOLDOWN'].includes(status) ? '19' : status === 'PENDING' ? '2' : null);
    await errorCode(res, http, code); assert.equal(f.calls.length, 1); assert.equal(f.sends.length, 0);
  }
});

test('missing provider keys force cache-only BEFORE claim: hit works, miss is 503', async () => {
  for (const provider of ['golf', 'gpxz']) {
    for (const status of ['HIT', 'CACHE_MISS']) {
      const f = fixture({ providers: { configured: { golf: false, gpxz: false } },
        claim: status === 'HIT' ? hit(course) : { status } });
      const res = await f.handler(provider === 'golf' ? request() : post());
      assert.equal(f.calls[0][1].p_cache_only, true); assert.equal(f.sends.length, 0);
      if (status === 'HIT') assert.equal(res.status, 200);
      else await errorCode(res, 503, 'provider_not_configured');
    }
  }
  const f = fixture({ claim: { status: 'CACHE_MISS' } });
  await errorCode(await f.handler(request(undefined, { headers: { 'X-Cache-Only': 'true' } })), 404, 'cache_miss');
  assert.equal(f.calls[0][1].p_cache_only, true);
  const unsafe = fixture({ providers: { configured: {} }, claim: { status: 'CLAIMED', token: TOKEN } });
  assert.equal((await unsafe.handler(request())).status, 503); assert.equal(unsafe.sends.length, 0);
  assert.equal(unsafe.calls[1][0], 'pintheory_data_fail');
});

test('coalesced caller returns immediately while owner commits, without local waits or second claim', async () => {
  let release; const gate = new Promise(resolve => { release = resolve; });
  let claims = 0; let sends = 0;
  const f = fixture({ rpcImpl: async name => name === 'pintheory_data_claim'
    ? (++claims === 1 ? { status: 'CLAIMED', token: TOKEN } : { status: 'PENDING' }) : true,
    providers: { async golf() { sends++; await gate; return { body: course }; } } });
  const owner = f.handler(request());
  // Await provider entry without sleeps or timing assumptions.
  while (!sends) await new Promise(resolve => setImmediate(resolve));
  await errorCode(await f.handler(request()), 503, 'request_pending');
  assert.equal(claims, 2); assert.equal(sends, 1);
  release(); assert.equal((await owner).headers.get('x-cache'), 'MISS');
  assert.equal(f.calls.filter(([name]) => name === 'pintheory_data_finish').length, 1);
});

test('successful owner finishes once with original body, version, key and fencing token', async () => {
  const f = fixture({ claim: { status: 'CLAIMED', token: TOKEN } });
  const res = await f.handler(request());
  assert.equal(res.status, 200); assert.equal(res.headers.get('x-cache'), 'MISS');
  assert.ok(Number.isFinite(Date.parse(res.headers.get('x-fetched-at'))));
  assert.deepEqual(f.calls[1], ['pintheory_data_finish', { p_key: 'golf:v1:detail:A', p_token: TOKEN,
    p_body: course, p_dataset_version: 'v1', p_metadata: {} }]);
});

test('finish exception/false (late fencing rejection) never fails, reclaims, sends or reports success', async () => {
  for (const outcome of [false, new Error(`${SECRET} uncertain commit`)]) {
    const f = fixture({ rpcImpl: async name => {
      if (name === 'pintheory_data_claim') return { status: 'CLAIMED', token: TOKEN };
      if (outcome instanceof Error) throw outcome;
      return outcome;
    } });
    const res = await f.handler(request());
    assert.equal(res.status, 503); assert.equal(res.headers.get('x-cache'), null);
    assert.ok(!(await res.text()).includes(SECRET));
    assert.deepEqual(f.calls.map(([name]) => name), ['pintheory_data_claim', 'pintheory_data_finish']);
    assert.equal(f.sends.length, 1);
  }
});

test('provider exception persisted once with bounded cooldown; fail persistence failure does not replay', async () => {
  for (const persistenceFailure of [false, true]) {
    let sends = 0;
    const f = fixture({ providers: { async golf() {
      sends++; const error = new APIError(502, 'invalid_provider_response', 'Provider returned invalid data.', 600);
      error.providerWide = false; throw error;
    } }, rpcImpl: async name => {
      if (name === 'pintheory_data_claim') return { status: 'CLAIMED', token: TOKEN };
      if (persistenceFailure) throw new Error(SECRET);
      return true;
    } });
    const res = await f.handler(request());
    await errorCode(res, persistenceFailure ? 503 : 502, persistenceFailure ? 'service_unavailable' : 'invalid_provider_response');
    assert.equal(sends, 1);
    assert.deepEqual(f.calls[1], ['pintheory_data_fail', { p_key: 'golf:v1:detail:A', p_token: TOKEN,
      p_provider_wide: false, p_retry_after: 600 }]);
    assert.equal(f.calls.length, 2);
  }
});

test('elevation JSON/form normalize to identical source key; course association excluded from key/provider', async () => {
  const a = fixture({ claim: { status: 'CLAIMED', token: TOKEN } });
  const b = fixture({ claim: { status: 'CLAIMED', token: TOKEN } });
  assert.equal((await a.handler(post({ path: [path[0], path[0], path[1]], samples: 3, courseID: 'A' }))).status, 200);
  const form = new URLSearchParams({ latlons: path.map(p => `${p.lat},${p.lon}`).join('|'), samples: '3', courseID: 'B',
    interpolation: 'bilinear', bathymetry: 'false' });
  assert.equal((await b.handler(request('/api/v1/elevation/sample', { method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' }, body: form }))).status, 200);
  const key = `gpxz:sample:v1:${sha(JSON.stringify({ path, samples: 3, interpolation: 'bilinear', bathymetry: false }))}`;
  assert.equal(a.calls[0][1].p_key, key); assert.equal(b.calls[0][1].p_key, key);
  assert.equal(a.calls[1][1].p_metadata.courseID, 'A'); assert.equal(b.calls[1][1].p_metadata.courseID, 'B');
  assert.equal(a.calls[1][1].p_metadata.profileLengthMeters, profileRequest(sample).length);
  assert.ok(!own(a.sends[0][1], 'courseID')); assert.deepEqual(a.sends, b.sends);
  const c = fixture({ claim: hit(elevation(profileRequest(sample))) });
  assert.equal((await c.handler(post({ ...sample, courseID: 'C' }))).status, 200);
  assert.deepEqual(c.calls[1], ['pintheory_data_tag', { p_key: key, p_course_id: 'C' }]);
  const d = fixture({ claim: { status: 'CLAIMED', token: TOKEN } });
  await d.handler(post()); assert.ok(!own(d.calls[1][1].p_metadata, 'courseID'));
});
const own = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key);

test('elevation strict schema/geometry/body limits reject before claim', async () => {
  for (const body of [null, [], {}, { ...sample, extra: true }, { ...sample, path: [{ ...path[0], extra: true }, path[1]] },
    { ...sample, path: [{ lat: '57', lon: 12 }, path[1]] }, { ...sample, latlons: '57,12|57.01,12' },
    { ...sample, samples: '1e2' }, { ...sample, samples: null }, { ...sample, samples: true }, { ...sample, samples: 513 },
    { ...sample, samples: 1 }, { ...sample, courseID: 'bad:id' }, { ...sample, courseID: null },
    { ...sample, path: [path[0], path[0]] }, { ...sample, path: [{ lat: 91, lon: 0 }, path[1]] },
    { ...sample, path: [{ lat: 0, lon: 0 }, { lat: 1, lon: 1 }] },
    { ...sample, interpolation: 'nearest' }, { ...sample, bathymetry: true },
    { ...sample, latlons: 'x'.repeat(250001), path: undefined }]) {
    const f = fixture(); assert.equal((await f.handler(post(body))).status, 400, JSON.stringify(body).slice(0, 100));
    assert.equal(f.calls.length, 0);
  }
  for (const text of ['latlons=57,12|57.0001,12&samples=2&samples=2', 'url=evil', 'path=%5B%5D']) {
    const f = fixture();
    assert.equal((await f.handler(request('/api/v1/elevation/sample', { method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: text }))).status, 400);
    assert.equal(f.calls.length, 0);
  }
  for (const [body, headers, status] of [['{broken', { 'Content-Type': 'application/json' }, 400],
    ['x'.repeat(300001), { 'Content-Type': 'application/json' }, 413],
    ['{}', { 'Content-Type': 'application/json', 'Content-Length': '300001' }, 413],
    ['{}', { 'Content-Type': 'text/plain' }, 415]]) {
    const f = fixture();
    assert.equal((await f.handler(request('/api/v1/elevation/sample', { method: 'POST', body, headers }))).status, status);
    assert.equal(f.calls.length, 0);
  }
});

function realProviders(fetchImpl, overrides = {}) {
  return new Providers({ providers: { golf: { key: 'golf-fixture-key' }, gpxz: { key: 'gpxz-fixture-key' } } },
    { fetchImpl, ...overrides });
}

test('real provider transport uncertainty leaves dispatched job/reservation; later callers never pay again', async () => {
  const failures = [
    async () => { throw new TypeError(`${SECRET} network rejection`); },
    async () => new Promise(() => {}), // Fetch never resolves, even on abort.
    async () => new Response(new ReadableStream({
      start(c) { c.enqueue(new TextEncoder().encode('{"partial":')); },
      pull(c) { c.error(new Error(`${SECRET} truncated stream`)); }
    })),
    async () => new Response(new ReadableStream({})), // Body read timeout.
    async () => new Response('{malformed'),
    async () => new Response('x', { headers: { 'Content-Length': '4000001' } })
  ];
  for (const makeRequest of [request, post]) {
    for (const fetchImpl of failures) {
      let sends = 0; let reservations = 0; let state; let expired = false;
      const calls = [];
      const handler = createHandler({ authenticate: async () => ({ id: UID }),
        providers: realProviders(async (...args) => { sends++; return fetchImpl(...args); }, { timeoutMs: 5 }),
        rpc: async name => {
          calls.push(name);
          assert.equal(name, 'pintheory_data_claim', 'uncertain attempt must not fail or finish');
          if (state === 'dispatched') return { status: expired ? 'UNKNOWN' : 'PENDING' };
          state = 'dispatched'; reservations++;
          return { status: 'CLAIMED', token: TOKEN };
        } });
      const res = await handler(makeRequest());
      assert.equal(res.headers.get('retry-after'), null);
      assert.equal(res.headers.get('x-cache'), null);
      const body = await res.clone().text();
      assert.ok(!body.includes(SECRET)); assert.match(body, /operator resolution is required/);
      await errorCode(res, 503, 'ambiguous_attempt');
      await errorCode(await handler(makeRequest()), 503, 'request_pending');
      expired = true;
      await errorCode(await handler(makeRequest()), 503, 'ambiguous_attempt');
      assert.equal(state, 'dispatched'); assert.equal(reservations, 1); assert.equal(sends, 1);
      assert.deepEqual(calls, Array(3).fill('pintheory_data_claim'));
    }
  }
});

test('unknown injected exceptions are ambiguous even when they claim to be definitive', async () => {
  const marked = new APIError(502, 'provider_unavailable', SECRET, 300);
  marked.ambiguous = true;
  for (const error of [new Error(SECRET), { ambiguous: false, providerWide: false }, null, marked]) {
    let sends = 0;
    const f = fixture({ claim: { status: 'CLAIMED', token: TOKEN },
      providers: { async golf() { sends++; throw error; } } });
    const res = await f.handler(request());
    assert.equal(res.headers.get('retry-after'), null);
    await errorCode(res, 503, 'ambiguous_attempt');
    assert.equal(sends, 1); assert.deepEqual(f.calls.map(([name]) => name), ['pintheory_data_claim']);
  }
});

test('real known 429 fails once with cooldown; complete invalid data can fail normally', async () => {
  for (const invalidBody of [false, true]) {
    let sends = 0; let failed = false;
    const calls = [];
    const handler = createHandler({ authenticate: async () => ({ id: UID }),
      providers: realProviders(async () => {
        sends++;
        return invalidBody ? json({ courseID: 'wrong' })
          : new Response(SECRET, { status: 429, headers: { 'Retry-After': '600' } });
      }),
      rpc: async (name, args) => {
        calls.push([name, args]);
        if (name === 'pintheory_data_claim') return failed ? { status: 'COOLDOWN', retryAfter: 600 }
          : { status: 'CLAIMED', token: TOKEN };
        assert.equal(name, 'pintheory_data_fail'); failed = true; return true;
      } });
    await errorCode(await handler(request()), 502, invalidBody ? 'invalid_provider_response' : 'provider_unavailable');
    assert.deepEqual(calls[1], ['pintheory_data_fail', { p_key: 'golf:v1:detail:A', p_token: TOKEN,
      p_provider_wide: !invalidBody, p_retry_after: invalidBody ? 300 : 600 }]);
    await errorCode(await handler(request()), 503, 'provider_cooldown');
    assert.equal(sends, 1);
    assert.deepEqual(calls.map(([name]) => name), ['pintheory_data_claim', 'pintheory_data_fail', 'pintheory_data_claim']);
  }
});

test('real Providers exact fixed GolfAPI2.3 bearer/query formats and credit redaction', async () => {
  let calls = 0;
  const providers = realProviders(async (url, options) => {
    calls++; assert.equal(String(url), 'https://golfapi.io/api/v2.3/clubs?country=SE&name=%C3%85&page=1');
    assert.deepEqual(options.headers, { Authorization: 'Bearer golf-fixture-key', Accept: 'application/json' });
    assert.equal(options.redirect, 'error'); assert.ok(options.signal instanceof AbortSignal);
    return json({ clubs: [{ clubID: '1', clubName: 'Å' }], apiRequestsLeft: 123 }, { headers: { 'x-dataset-version': 'v1' } });
  });
  const result = await providers.golf('/clubs', { country: 'SE', name: 'Å', page: '1' }, 'clubs');
  assert.deepEqual(result, { body: { clubs: [{ clubID: '1', clubName: 'Å' }] }, datasetVersion: 'v1' });
  assert.equal(calls, 1);
});

test('real Providers GPXZ fixed form uses original vertices (not resampled), validates exact output', async () => {
  const profile = profileRequest(sample);
  const expected = elevation(profile);
  let calls = 0;
  const providers = realProviders(async (url, options) => {
    calls++; assert.equal(url, 'https://api.gpxz.io/v1/elevation/sample');
    assert.equal(options.method, 'POST'); assert.equal(options.redirect, 'error');
    assert.deepEqual(options.headers, { 'x-api-key': 'gpxz-fixture-key', 'Content-Type': 'application/x-www-form-urlencoded' });
    assert.equal(options.body, new URLSearchParams({ latlons: path.map(p => `${p.lat},${p.lon}`).join('|'),
      samples: '3', interpolation: 'bilinear', bathymetry: 'false' }).toString());
    return json(expected);
  });
  assert.deepEqual((await providers.elevation(profile)).body, expected); assert.equal(calls, 1);
  assert.deepEqual(profile.path, path);
});

test('real provider validation rejects wrong IDs, coordinate shape, nonfinite/offset samples and missing metadata', () => {
  for (const [body, kind, id] of [[[], 'clubs'], [{ clubs: [{}] }, 'clubs'],
    [{ courses: [{ courseID: 'A' }] }, 'courses'], [{ ...course, courseID: 'B' }, 'detail', 'A'],
    [{ courseID: 'A', coordinates: [] }, 'coordinates', 'A'],
    [{ courseID: 'A', coordinates: [{ poi: 1, hole: 1, latitude: 91, longitude: 12 }] }, 'coordinates', 'A']]) {
    assert.throws(() => validateGolf(body, kind, id), { code: 'invalid_provider_response' });
  }
  assert.deepEqual(validateGolf({ courseID: 'A', coordinates: [{ poi: '1', hole: '2', latitude: '57', longitude: '12' }] },
    'coordinates', 'A').courseID, 'A');
  const profile = profileRequest(sample);
  for (const mutate of [b => { b.status = 'ERROR'; }, b => { b.results.pop(); },
    b => { b.results[0].lat += 0.0001; }, b => { b.results[1].lon += 0.0001; },
    b => { b.results[1].elevation = Infinity; }, b => { b.results[1].resolution = 0; },
    b => { delete b.results[1].data_source; }, b => { b.results.reverse(); }]) {
    const body = elevation(profile); mutate(body);
    assert.throws(() => validateElevation(body, profile), { code: 'invalid_provider_response', providerWide: false });
  }
  const dateline = profileRequest({ path: [{ lat: 0, lon: 179.999 }, { lat: 0, lon: -179.999 }], samples: 3 });
  assert.ok(Math.abs(pointAt(dateline, dateline.length / 2).lon) > 179.99);
  assert.equal(distance(dateline.path[0], pointAt(dateline, 0)), 0);
  assert.deepEqual(validateElevation(elevation(dateline), dateline), elevation(dateline));
});

test('provider missing keys never sends; HTTP/error/redirect/JSON/UTF8/size/timeout sanitized without retries', async () => {
  const disabled = new Providers({ providers: {} }, { fetchImpl: () => assert.fail('missing key dispatched') });
  await assert.rejects(disabled.golf('/clubs', {}, 'clubs'), { code: 'provider_not_configured' });
  await assert.rejects(disabled.elevation(profileRequest(sample)), { code: 'provider_not_configured' });
  for (const status of [301, 401, 403, 404, 429, 500]) {
    let calls = 0; let cancelled = false;
    const providers = realProviders(async () => {
      calls++; return new Response(new ReadableStream({ cancel() { cancelled = true; } }),
        { status, headers: { 'Retry-After': '90000' } });
    });
    await assert.rejects(providers.golf('/clubs', {}, 'clubs'), error => {
      assert.equal(error.code, 'provider_unavailable'); assert.equal(error.retryAfter, 86400);
      assert.equal(error.ambiguous, false);
      assert.equal(error.providerWide, [401, 403, 429, 500].includes(status)); return true;
    });
    assert.equal(calls, 1); assert.equal(cancelled, true);
  }
  for (const fetchImpl of [async () => { throw new Error(SECRET); }, async () => new Response(SECRET),
    async () => new Response(new Uint8Array([0xff])), async () => {
      const res = json({ clubs: [] }); Object.defineProperty(res, 'redirected', { value: true }); return res;
    }, async () => new Response('x', { headers: { 'Content-Length': '4000001' } }),
    async () => new Response(new ReadableStream({ start(c) { c.enqueue(new Uint8Array(4000001)); } })),
    async () => new Response(new ReadableStream({ start(c) { c.error(new Error(SECRET)); } }))]) {
    await assert.rejects(realProviders(fetchImpl).golf('/clubs', {}, 'clubs'), error => {
      assert.equal(error.statusCode, 502); assert.equal(error.ambiguous, true);
      assert.ok(!error.message.includes(SECRET)); return true;
    });
  }
  let calls = 0;
  await assert.rejects(realProviders(async () => { calls++; return new Promise(() => {}); }, { timeoutMs: 5 })
    .golf('/clubs', {}, 'clubs'), { code: 'provider_unavailable', ambiguous: true });
  assert.equal(calls, 1);
  let cancelled = false;
  await assert.rejects(realProviders(async () => new Response(new ReadableStream({ cancel() { cancelled = true; } })),
    { timeoutMs: 5 }).golf('/clubs', {}, 'clubs'), { code: 'provider_unavailable', ambiguous: true });
  assert.equal(cancelled, true);
});

test('Supabase online getUser uses only fixed URL, anon apikey + user bearer; strict nonanonymous UUID', async () => {
  const client = createSupabase({ url: URL_ROOT, anonKey: 'offline-anon', serviceKey: SECRET }, {
    fetchImpl: async (url, options) => {
      assert.equal(url, `${URL_ROOT}/auth/v1/user`); assert.equal(options.method, 'GET');
      assert.equal(options.redirect, 'error'); assert.ok(options.signal instanceof AbortSignal);
      assert.deepEqual(options.headers, { apikey: 'offline-anon', Authorization: 'Bearer user-token', Accept: 'application/json' });
      return json({ id: UID, is_anonymous: false, email: 'private@example.invalid' });
    }
  });
  assert.deepEqual(await client.authenticate('user-token'), { id: UID });
  for (const token of [SECRET, 'offline-anon', '']) await assert.rejects(client.authenticate(token), { statusCode: 401 });
  for (const body of [{ id: UID }, { id: UID, is_anonymous: true }, { id: 'x', is_anonymous: false }, null]) {
    const client = createSupabase({ url: URL_ROOT, anonKey: 'anon' }, { fetchImpl: async () => json(body) });
    await assert.rejects(client.authenticate('user-token'), { statusCode: 401 });
  }
});

test('Supabase RPC fixed allowlist/service-only POST, 200 only, no identity/raw error leaks or retries', async () => {
  for (const serviceKey of [SECRET, 'sb_secret_fixture']) {
    let calls = 0;
    const client = createSupabase({ url: URL_ROOT, anonKey: 'anon', serviceKey }, { fetchImpl: async (url, options) => {
      calls++; assert.equal(url, `${URL_ROOT}/rest/v1/rpc/pintheory_data_claim`);
      assert.equal(options.method, 'POST'); assert.equal(options.body, '{"p_user_id":"fixture"}');
      assert.deepEqual(options.headers, { apikey: serviceKey, 'Content-Type': 'application/json', Accept: 'application/json',
        ...(serviceKey.startsWith('sb_secret_') ? {} : { Authorization: `Bearer ${serviceKey}` }) });
      return json({ status: 'FORBIDDEN' });
    } });
    assert.deepEqual(await client.rpc('pintheory_data_claim', { p_user_id: 'fixture' }), { status: 'FORBIDDEN' });
    await assert.rejects(client.rpc('pintheory_data_admin_resolve', {}), { statusCode: 503 }); assert.equal(calls, 1);
  }
  for (const status of [201, 204, 301, 401, 403, 429, 500]) {
    let calls = 0;
    const client = createSupabase({ url: URL_ROOT, anonKey: 'anon', serviceKey: SECRET }, { fetchImpl: async () => {
      calls++; return new Response(status === 204 ? null : SECRET, { status });
    } });
    await assert.rejects(client.rpc('pintheory_data_claim', {}), error => {
      assert.equal(error.statusCode, 503); assert.ok(!error.message.includes(SECRET)); return true;
    });
    assert.equal(calls, 1);
  }
});

test('Supabase auth failure, bad JSON/UTF8/oversize/redirect/stream/timeout/config fail closed', async () => {
  for (const status of [401, 403]) {
    const client = createSupabase({ url: URL_ROOT, anonKey: 'anon' }, { fetchImpl: async () => new Response(SECRET, { status }) });
    await assert.rejects(client.authenticate('user-token'), { statusCode: 401 });
  }
  for (const fetchImpl of [async () => new Response(SECRET), async () => new Response(new Uint8Array([255])),
    async () => new Response('x'.repeat(256001)), async () => { throw new Error(SECRET); },
    async () => { const res = json({}); Object.defineProperty(res, 'redirected', { value: true }); return res; },
    async () => new Response(new ReadableStream({ start(c) { c.error(new Error(SECRET)); } })),
    async () => new Promise(() => {})]) {
    const client = createSupabase({ url: URL_ROOT, anonKey: 'anon', serviceKey: SECRET }, { fetchImpl, timeoutMs: 5 });
    await assert.rejects(client.authenticate('user-token'), error => {
      assert.equal(error.statusCode, 503); assert.ok(!error.message.includes(SECRET)); return true;
    });
  }
  for (const url of [undefined, 'bad', 'https://user:secret@example.invalid/', 'https://example.invalid/path', 'https://example.invalid/?token=secret']) {
    const client = createSupabase({ url, anonKey: 'anon', serviceKey: SECRET }, { fetchImpl: () => assert.fail('bad config dispatched') });
    await assert.rejects(client.authenticate('user-token'), { statusCode: 503 });
    await assert.rejects(client.rpc('pintheory_data_claim', {}), { statusCode: 503 });
  }
});