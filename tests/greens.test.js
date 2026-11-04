import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHandler, greenBounds } from '../supabase/functions/golf-data/handler.js';
import { greenRow, parseBounds, importRegion } from '../scripts/import-osm-greens.mjs';

const UID = '24000002-0000-4000-8000-000000000001';
const ROOT = 'https://edge.example.invalid/functions/v1/golf-data';
const originalFetch = globalThis.fetch;
before(() => { globalThis.fetch = () => { throw new Error('No network allowed'); }; });
after(() => { globalThis.fetch = originalFetch; });
const request = suffix => new Request(`${ROOT}${suffix}`, { headers: { Authorization: 'Bearer offline-user' } });

const square = (lat, lon) => [[0, 0], [0, 0.0002], [0.0002, 0.0002], [0.0002, 0], [0, 0]]
  .map(([dLat, dLon]) => [lat + dLat, lon + dLon]);
const coordinates = { courseID: 'A', coordinates: [
  { poi: 1, hole: 1, location: 2, latitude: 57.62, longitude: 12.0 },
  { poi: 1, hole: 2, location: 2, latitude: 57.625, longitude: 12.01 },
  { poi: 11, hole: 1, latitude: 57.7, longitude: 12.3 }] };

function greensFixture({ catalog, coordinatesClaim = { status: 'HIT', body: coordinates } }) {
  const calls = [];
  const handler = createHandler({
    authenticate: async () => ({ id: UID }),
    providers: { configured: { golf: true, gpxz: true }, async golf() { throw new Error('greens must never buy GolfAPI data'); } },
    rpc: async (name, args) => {
      calls.push([name, args]);
      if (name === 'pintheory_osm_greens') return catalog(args);
      return name === 'pintheory_data_claim' ? coordinatesClaim : true;
    } });
  return { handler, calls };
}

test('green box covers the green points only, with a margin, and rejects huge spreads', () => {
  assert.deepEqual(greenBounds(coordinates.coordinates), { bottom: 57.619, top: 57.626, left: 11.998, right: 12.012 });
  assert.equal(greenBounds([]), null);
  assert.equal(greenBounds([{ poi: 1, latitude: 57, longitude: 12 }, { poi: 1, latitude: 57, longitude: 12.5 }]), null);
});

test('greens come from our own catalog around the cached course, never from a provider', async () => {
  const f = greensFixture({ catalog: () => ({ status: 'OK', covered: true, greens: [square(57.62, 12.0), [[91, 0]]] }) });
  const res = await f.handler(request('/api/v1/golf/courses/A/greens'));
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.covered, true);
  assert.equal(body.greens.length, 1);
  assert.deepEqual(body.greens[0][1], { lat: 57.62, lon: 12.0002 });
  const coordinateClaim = f.calls.find(([name]) => name === 'pintheory_data_claim')[1];
  assert.equal(coordinateClaim.p_cache_only, true);
  assert.deepEqual(f.calls.find(([name]) => name === 'pintheory_osm_greens')[1],
    { p_user_id: UID, p_min_lat: 57.619, p_min_lon: 11.998, p_max_lat: 57.626, p_max_lon: 12.012 });
});

test('catalog refusals map to the usual errors; an uncached course never reaches the catalog', async () => {
  const limited = await greensFixture({ catalog: () => ({ status: 'RATE_LIMIT', retryAfter: 60 }) })
    .handler(request('/api/v1/golf/courses/A/greens'));
  assert.equal(limited.status, 429);
  assert.equal((await greensFixture({ catalog: () => ({ status: 'FORBIDDEN' }) })
    .handler(request('/api/v1/golf/courses/A/greens'))).status, 403);
  assert.equal((await greensFixture({ catalog: () => ({ status: 'OK' }) })
    .handler(request('/api/v1/golf/courses/A/greens'))).status, 503);
  const uncached = greensFixture({ coordinatesClaim: { status: 'CACHE_MISS' }, catalog: () => { throw new Error('no'); } });
  assert.equal((await uncached.handler(request('/api/v1/golf/courses/A/greens'))).status, 404);
  assert.equal(uncached.calls.some(([name]) => name === 'pintheory_osm_greens'), false);
});

test('greens route accepts only the strict course ID and no query', async () => {
  const f = greensFixture({ catalog: () => ({ status: 'OK', covered: true, greens: [] }) });
  for (const suffix of ['/api/v1/golf/courses/A/greens/x', '/api/v1/golf/courses/A%2FB/greens', '/api/v1/golf/courses/A/greens?x=1']) {
    assert.notEqual((await f.handler(request(suffix))).status, 200, suffix);
  }
});

const feature = (type, id, geometry) => ({ type: 'Feature', properties: { '@type': type, '@id': id }, geometry });
const lonLat = ring => ring.map(([lat, lon]) => [lon, lat]);

test('osmium features become catalog rows; whole courses and junk are skipped', () => {
  const row = greenRow(feature('way', 7, { type: 'Polygon', coordinates: [lonLat(square(57.62, 12.0))] }));
  assert.deepEqual([row.type, row.id, row.minLat, row.maxLon, row.ring.length], ['way', 7, 57.62, 12.0002, 5]);
  assert.deepEqual(row.ring[1], [57.62, 12.0002]);
  const multi = greenRow(feature('relation', 8, { type: 'MultiPolygon', coordinates: [
    [lonLat(square(57.62, 12.0)).slice(0, 4).concat([lonLat(square(57.62, 12.0))[0]])],
    [lonLat([[57.63, 12.0], [57.63, 12.0001], [57.6302, 12.0002], [57.6302, 12.0001], [57.6301, 12.0], [57.63, 12.0]])]] }));
  assert.equal(multi.ring.length, 6);
  const course = [[57.6, 12.0], [57.6, 12.1], [57.65, 12.1], [57.6, 12.0]];
  assert.equal(greenRow(feature('way', 9, { type: 'Polygon', coordinates: [lonLat(course)] })), null);
  assert.equal(greenRow(feature('node', 1, { type: 'Point', coordinates: [12, 57] })), null);
  assert.deepEqual(parseBounds('(10.5,55.0,24.2,69.1)'), { minLon: 10.5, minLat: 55, maxLon: 24.2, maxLat: 69.1 });
  assert.throws(() => parseBounds(''));
});

test('a region import sends batches, then completes the region; an empty extract keeps existing data', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'greens-'));
  try {
    const file = join(dir, 'greens.geojsonseq');
    const lines = Array.from({ length: 501 }, (_, i) =>
      `\x1e${JSON.stringify(feature('way', i + 1, { type: 'Polygon', coordinates: [lonLat(square(57.62, 12.0))] }))}`);
    writeFileSync(file, `${lines.join('\n')}\n\x1e{broken\n`);
    const calls = [];
    const fetchImpl = async (url, options) => {
      const body = JSON.parse(options.body);
      calls.push([String(url).split('/').pop(), body]);
      assert.equal(options.headers.apikey, 'service-key');
      return new Response(JSON.stringify(url.endsWith('import') ? body.p_rows.length : 501));
    };
    const result = await importRegion({ region: 'europe/sweden', file, bounds: parseBounds('(10,55,24,69)'),
      projectRef: 'abcdefghijklmnopqrst', serviceKey: 'service-key', fetchImpl, log: () => {} });
    assert.deepEqual(result, { imported: 501, kept: 501 });
    assert.deepEqual(calls.map(([name]) => name), ['pintheory_osm_greens_import', 'pintheory_osm_greens_import', 'pintheory_osm_greens_finish']);
    assert.equal(calls[0][1].p_rows.length, 500);
    assert.equal(calls[0][1].p_started_at, calls[2][1].p_started_at);
    assert.deepEqual([calls[2][1].p_min_lat, calls[2][1].p_max_lon], [55, 24]);

    writeFileSync(file, '');
    const empty = [];
    await assert.rejects(importRegion({ region: 'europe/sweden', file, bounds: parseBounds('(10,55,24,69)'),
      projectRef: 'abcdefghijklmnopqrst', serviceKey: 'k', fetchImpl: async url => { empty.push(url); return new Response('0'); },
      log: () => {} }), /existing data kept/);
    assert.equal(empty.length, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
