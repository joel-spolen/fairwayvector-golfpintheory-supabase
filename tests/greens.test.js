import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createHandler, greenBounds } from '../supabase/functions/golf-data/handler.js';
import { Providers, validateGreens } from '../supabase/functions/_shared/providers.js';
import { APIError } from '../supabase/functions/_shared/errors.js';

const UID = '24000002-0000-4000-8000-000000000001';
const TOKEN = '24000002-0000-4000-8000-000000000002';
const ROOT = 'https://edge.example.invalid/functions/v1/golf-data';
const originalFetch = globalThis.fetch;
before(() => { globalThis.fetch = () => { throw new Error('No network allowed'); }; });
after(() => { globalThis.fetch = originalFetch; });
const request = (suffix, headers = {}) => new Request(`${ROOT}${suffix}`,
  { headers: { Authorization: 'Bearer offline-user', ...headers } });

const ring = (lat, lon) => [[0, 0], [0, 0.0002], [0.0002, 0.0002], [0, 0]]
  .map(([dLat, dLon]) => ({ lat: lat + dLat, lon: lon + dLon }));
const overpass = (elements, extra = {}) => ({ osm3s: { timestamp_osm_base: '2026-11-04T08:00:00Z' }, elements, ...extra });
const coordinates = { courseID: 'A', coordinates: [
  { poi: 1, hole: 1, location: 2, latitude: 57.62, longitude: 12.0 },
  { poi: 1, hole: 2, location: 2, latitude: 57.625, longitude: 12.01 },
  { poi: 11, hole: 1, latitude: 57.7, longitude: 12.3 }] };

test('Overpass greens keep only complete, valid rings and the data timestamp', () => {
  const good = ring(57.62, 12.0);
  const parsed = validateGreens(overpass([
    { type: 'way', id: 1, geometry: good },
    { type: 'way', id: 2, geometry: good.slice(0, 3) },
    { type: 'way', id: 3, geometry: [...good.slice(0, 3), { lat: 91, lon: 0 }] },
    { type: 'node', id: 4, lat: 57, lon: 12 },
    { type: 'way', id: 5, geometry: ring(57.621234567891, 12.000000049).map(p => p) }]));
  assert.equal(parsed.greens.length, 2);
  assert.deepEqual(parsed.greens[0], good);
  assert.equal(parsed.greens[1][0].lat, 57.6212346);
  assert.equal(parsed.datasetVersion, 'osm-2026-11-04T08:00:00Z');
  assert.throws(() => validateGreens(overpass([], { remark: 'runtime error: timed out' })), { code: 'invalid_provider_response' });
  assert.throws(() => validateGreens({}), { code: 'invalid_provider_response' });
});

test('green box covers the green points only, with a margin, and rejects huge spreads', () => {
  const bounds = greenBounds(coordinates.coordinates);
  assert.deepEqual(bounds, { bottom: 57.619, top: 57.626, left: 11.998, right: 12.012 });
  assert.equal(greenBounds([]), null);
  assert.equal(greenBounds([{ poi: 1, latitude: 57, longitude: 12 }, { poi: 1, latitude: 57, longitude: 12.5 }]), null);
});

test('Overpass request asks both servers, takes the first good answer and never reports ambiguity', async () => {
  const urls = [];
  const providers = new Providers({ providers: {} }, { fetchImpl: async (url, options) => {
    urls.push(String(url));
    assert.equal(options.method, 'POST');
    assert.match(options.headers['User-Agent'], /^GolfPinTheory\//);
    assert.match(decodeURIComponent(options.body), /way\["golf"="green"\]\(57\.619,11\.998,57\.626,12\.012\);out geom;$/);
    if (String(url).includes('kumi')) return new Response('busy', { status: 429 });
    return new Response(JSON.stringify(overpass([{ type: 'way', geometry: ring(57.62, 12) }])));
  } });
  assert.equal(providers.configured.osm, true);
  const result = await providers.greenOutlines(greenBounds(coordinates.coordinates));
  assert.equal(result.greens.length, 1);
  assert.equal(new Set(urls).size, 2);

  const down = new Providers({ providers: {} }, { overpassPauseMs: 5, overpassBudgetMs: 60,
    fetchImpl: async () => { throw new TypeError('network'); } });
  await assert.rejects(down.greenOutlines({ bottom: 1, left: 1, top: 2, right: 2 }),
    { code: 'provider_unavailable', ambiguous: false, providerWide: false, retryAfter: 300 });

  let asked = 0;
  const hanging = new Promise(() => {});
  // One server hangs; the other refuses twice, then answers.
  const busyOnce = new Providers({ providers: {} }, { overpassPauseMs: 1, overpassBudgetMs: 2000, fetchImpl: async url => {
    if (String(url).includes('kumi')) return hanging;
    return ++asked <= 2 ? new Response('at capacity', { status: 502 })
      : new Response(JSON.stringify(overpass([{ type: 'way', geometry: ring(57.62, 12) }])));
  } });
  assert.equal((await busyOnce.greenOutlines({ bottom: 1, left: 1, top: 2, right: 2 })).greens.length, 1);
  assert.equal(asked, 3);
});

function greensFixture({ osmClaim, greenOutlines, coordinatesClaim = { status: 'HIT', body: coordinates } }) {
  const calls = [], sends = [];
  const handler = createHandler({
    authenticate: async () => ({ id: UID }),
    providers: { configured: { golf: true, gpxz: true, osm: true },
      async golf() { throw new Error('greens must never buy GolfAPI data'); },
      async greenOutlines(bounds) { sends.push(bounds); return greenOutlines(bounds); } },
    rpc: async (name, args) => {
      calls.push([name, args]);
      if (name !== 'pintheory_data_claim') return true;
      if (args.p_key === 'golf:v1:coordinates:A') return coordinatesClaim;
      return osmClaim(args);
    } });
  return { handler, calls, sends };
}

test('greens route fetches once per course, keeps the result until removed and serves later hits', async () => {
  const greens = [ring(57.62, 12.0)];
  const first = greensFixture({ osmClaim: () => ({ status: 'CLAIMED', token: TOKEN }),
    greenOutlines: () => ({ greens, datasetVersion: 'osm-2026-11-04T08:00:00Z' }) });
  const res = await first.handler(request('/api/v1/golf/courses/A/greens'));
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { greens });
  assert.equal(res.headers.get('x-cache'), 'MISS');
  const [coordinateClaim, osmClaim] = first.calls.filter(([name]) => name === 'pintheory_data_claim').map(([, a]) => a);
  assert.equal(coordinateClaim.p_cache_only, true);
  assert.deepEqual([osmClaim.p_key, osmClaim.p_provider, osmClaim.p_cache_only, osmClaim.p_max_age_seconds],
    ['osm:greens:v1:A', 'osm', false, null]);
  const finish = first.calls.find(([name]) => name === 'pintheory_data_finish')[1];
  assert.deepEqual(finish.p_body, { greens }); assert.deepEqual(finish.p_metadata, {});
  assert.equal(finish.p_dataset_version, 'osm-2026-11-04T08:00:00Z');
  assert.deepEqual(first.sends, [{ bottom: 57.619, top: 57.626, left: 11.998, right: 12.012 }]);

  const cached = greensFixture({ osmClaim: () => ({ status: 'HIT', body: { greens } }),
    greenOutlines: () => { throw new Error('cached greens must not refetch'); } });
  const hit = await cached.handler(request('/api/v1/golf/courses/A/greens'));
  assert.equal(hit.status, 200); assert.deepEqual(await hit.json(), { greens });
});

test('an unreachable map server reports a retryable, per-course error', async () => {
  const failing = () => { const e = new APIError(502, 'provider_unavailable', 'x', 300); e.ambiguous = false; e.providerWide = false; throw e; };
  const none = greensFixture({ greenOutlines: failing, osmClaim: () => ({ status: 'CLAIMED', token: TOKEN }) });
  const missing = await none.handler(request('/api/v1/golf/courses/A/greens'));
  assert.equal(missing.status, 502); assert.equal((await missing.json()).error.code, 'provider_unavailable');
  const fail = none.calls.find(([name]) => name === 'pintheory_data_fail')[1];
  assert.equal(fail.p_provider_wide, false); assert.equal(fail.p_retry_after, 300);

  const pending = greensFixture({ greenOutlines: failing, osmClaim: () => ({ status: 'PENDING', retryAfter: 1 }) });
  const busy = await pending.handler(request('/api/v1/golf/courses/A/greens'));
  assert.equal(busy.status, 503); assert.equal((await busy.json()).error.code, 'request_pending');

  const uncached = greensFixture({ coordinatesClaim: { status: 'CACHE_MISS' }, osmClaim: () => { throw new Error('no'); },
    greenOutlines: () => { throw new Error('no'); } });
  assert.equal((await uncached.handler(request('/api/v1/golf/courses/A/greens'))).status, 404);
  assert.equal(uncached.sends.length, 0);
});

test('greens route accepts only the strict course ID and no query', async () => {
  const f = greensFixture({ osmClaim: () => ({ status: 'HIT', body: { greens: [] } }), greenOutlines: () => ({ greens: [] }) });
  for (const suffix of ['/api/v1/golf/courses/A/greens/x', '/api/v1/golf/courses/A%2FB/greens', '/api/v1/golf/courses/A/greens?x=1']) {
    assert.notEqual((await f.handler(request(suffix))).status, 200, suffix);
  }
});

test('the first course download starts the green outlines in the background without delaying the course', async () => {
  const detail = { courseID: 'A', courseName: 'Å Links' };
  const calls = [], started = [];
  let release;
  const slow = new Promise(resolve => { release = resolve; });
  const handler = createHandler({
    authenticate: async () => ({ id: UID }),
    background: promise => started.push(promise),
    providers: { configured: { golf: true, gpxz: false, osm: true },
      async greenOutlines() { await slow; return { greens: [ring(57.62, 12.0)] }; } },
    rpc: async (name, args) => {
      calls.push([name, args]);
      if (name !== 'pintheory_data_claim') return true;
      if (args.p_key === 'golf:v1:detail:A') return { status: 'HIT', body: detail };
      if (args.p_key === 'golf:v1:coordinates:A') return { status: 'HIT', body: coordinates };
      if (args.p_provider === 'osm') return { status: 'CLAIMED', token: TOKEN };
      return { status: 'CACHE_MISS' };
    } });
  const res = await handler(request('/api/v1/golf/courses/A/bundle'));
  assert.equal(res.status, 200);
  assert.equal(started.length, 1);
  assert.equal(calls.some(([name]) => name === 'pintheory_data_finish'), false, 'the course does not wait for the map servers');
  release();
  await started[0];
  const finish = calls.find(([name]) => name === 'pintheory_data_finish')[1];
  assert.equal(finish.p_key, 'osm:greens:v1:A'); assert.equal(finish.p_body.greens.length, 1);

  const quiet = createHandler({ authenticate: async () => ({ id: UID }), background: promise => started.push(promise),
    providers: { configured: { golf: true, osm: true }, async greenOutlines() { throw new Error('offline'); } },
    rpc: async (name, args) => name !== 'pintheory_data_claim' ? true
      : args.p_key === 'golf:v1:detail:A' ? { status: 'HIT', body: detail }
      : args.p_key === 'golf:v1:coordinates:A' ? { status: 'HIT', body: coordinates }
      : args.p_provider === 'osm' ? { status: 'CLAIMED', token: TOKEN } : { status: 'CACHE_MISS' } });
  assert.equal((await quiet(request('/api/v1/golf/courses/A/bundle'))).status, 200);
  await assert.doesNotReject(started[1], 'a failed background fetch never surfaces');
});
