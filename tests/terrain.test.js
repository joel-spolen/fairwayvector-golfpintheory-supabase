import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createHandler } from '../supabase/functions/golf-data/handler.js';
import { Providers } from '../supabase/functions/_shared/providers.js';
import { decodeTiff, decodeLZW } from '../supabase/functions/_shared/tiff.js';
import { courseBounds, terrainTiles, packGrid } from '../supabase/functions/_shared/terrain.js';
import { coveringItems, lantmaterietGrid, toSweref99TM } from '../supabase/functions/_shared/lantmateriet.js';

const UID = '24000002-0000-4000-8000-000000000001';
const TOKEN = '24000002-0000-4000-8000-000000000002';
const ROOT = 'https://edge.example.invalid/functions/v1/golf-data';
const originalFetch = globalThis.fetch;
before(() => { globalThis.fetch = () => { throw new Error('No network allowed'); }; });
after(() => { globalThis.fetch = originalFetch; });
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const request = suffix => new Request(`${ROOT}${suffix}`, { headers: { Authorization: 'Bearer offline-user' } });

async function compress(bytes, format) {
  const stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream(format));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}
async function decompress(bytes, format) {
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream(format));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

// Short inputs only: the code width stays at 9 bits.
function lzwEncode(bytes) {
  const out = []; let buffer = 0, count = 0;
  const emit = code => {
    for (let i = 8; i >= 0; i--) {
      buffer = (buffer << 1) | ((code >> i) & 1);
      if (++count === 8) { out.push(buffer); buffer = 0; count = 0; }
    }
  };
  const table = new Map(); let next = 258;
  const code = w => w.length === 1 ? w.charCodeAt(0) : table.get(w);
  emit(256);
  let w = String.fromCharCode(bytes[0]);
  for (let i = 1; i < bytes.length; i++) {
    const wc = w + String.fromCharCode(bytes[i]);
    if (table.has(wc)) { w = wc; continue; }
    emit(code(w)); table.set(wc, next++); w = String.fromCharCode(bytes[i]);
  }
  emit(code(w)); emit(257);
  if (count) out.push(buffer << (8 - count));
  return new Uint8Array(out);
}

/** Builds a single-band float32 GeoTIFF with the given layout. */
async function buildTiff({ width, height, values, compression = 1, predictor = 1, tile = 0, little = true,
  scale = [0.00001, 0.00001, 0], tiepoint = [0, 0, 0, 12, 57, 0], metadata = null, bands = 1, big = false }) {
  const blockWidth = tile || width, blockHeight = tile || height;
  const across = Math.ceil(width / blockWidth), down = Math.ceil(height / blockHeight);
  const blocks = [];
  for (let by = 0; by < down; by++) {
    for (let bx = 0; bx < across; bx++) {
      const rows = tile ? blockHeight : Math.min(blockHeight, height - by * blockHeight);
      let raw = new Uint8Array(blockWidth * rows * 4);
      const view = new DataView(raw.buffer);
      for (let r = 0; r < rows; r++) {
        for (let c = 0; c < blockWidth; c++) {
          const x = bx * blockWidth + c, y = by * blockHeight + r;
          const value = x < width && y < height ? values[y * width + x] : 0;
          view.setFloat32((r * blockWidth + c) * 4, value, predictor === 3 ? false : little);
        }
      }
      if (predictor === 3) {
        const planes = new Uint8Array(raw.length), rowBytes = blockWidth * 4;
        for (let r = 0; r < rows; r++) {
          for (let c = 0; c < blockWidth; c++) {
            for (let b = 0; b < 4; b++) planes[r * rowBytes + b * blockWidth + c] = raw[r * rowBytes + c * 4 + b];
          }
          for (let i = rowBytes - 1; i > 0; i--) planes[r * rowBytes + i] -= planes[r * rowBytes + i - 1];
        }
        raw = planes;
      }
      blocks.push(compression === 8 ? await compress(raw, 'deflate') : compression === 5 ? lzwEncode(raw) : raw);
    }
  }
  const entries = [[256, 4, [width]], [257, 4, [height]], [258, 3, [32]], [259, 3, [compression]],
    [262, 3, [1]], [277, 3, [bands]], [284, 3, [1]], [317, 3, [predictor]], [339, 3, [3]],
    [33550, 12, scale], [33922, 12, tiepoint]];
  if (tile) entries.push([322, 4, [tile]], [323, 4, [tile]], [324, 4, blocks.map(() => 0)], [325, 4, blocks.map(b => b.length)]);
  else entries.push([273, 4, [0]], [278, 4, [height]], [279, 4, [blocks[0].length]]);
  if (metadata) entries.push([42112, 2, [...metadata].map(c => c.charCodeAt(0)).concat(0)]);
  entries.sort((a, b) => a[0] - b[0]);
  const sizes = { 2: 1, 3: 2, 4: 4, 12: 8, 16: 8 };
  // GPXZ returns BigTIFF: 16-byte header, 64-bit counts/offsets, LONG8 block offsets.
  if (big) for (const entry of entries) if (entry[0] === 324 || entry[0] === 273) entry[1] = 16;
  const head = big ? 16 : 8, countSize = big ? 8 : 2, entrySize = big ? 20 : 12, inline = big ? 8 : 4;
  const ifdSize = countSize + entries.length * entrySize + inline;
  let dataOffset = head + ifdSize;
  const extra = entries.map(([, type, values]) => {
    const bytes = sizes[type] * values.length;
    if (bytes <= inline) return null;
    const at = dataOffset; dataOffset += bytes + (bytes % 2); return at;
  });
  const blockOffsets = blocks.map(b => { const at = dataOffset; dataOffset += b.length; return at; });
  const out = new Uint8Array(dataOffset);
  const view = new DataView(out.buffer);
  out.set(little ? [0x49, 0x49] : [0x4d, 0x4d]);
  if (big) {
    view.setUint16(2, 43, little); view.setUint16(4, 8, little);
    view.setBigUint64(8, 16n, little); view.setBigUint64(16, BigInt(entries.length), little);
  } else {
    view.setUint16(2, 42, little); view.setUint32(4, 8, little); view.setUint16(8, entries.length, little);
  }
  const put = (type, at, value) => {
    if (type === 2) view.setUint8(at, value);
    else if (type === 3) view.setUint16(at, value, little);
    else if (type === 4) view.setUint32(at, value, little);
    else if (type === 16) view.setBigUint64(at, BigInt(value), little);
    else view.setFloat64(at, value, little);
  };
  entries.forEach(([tag, type, values], i) => {
    const entry = head + countSize + i * entrySize;
    const actual = tag === 324 || tag === 273 ? blockOffsets : values;
    view.setUint16(entry, tag, little); view.setUint16(entry + 2, type, little);
    if (big) view.setBigUint64(entry + 4, BigInt(actual.length), little);
    else view.setUint32(entry + 4, actual.length, little);
    const valueAt = entry + (big ? 12 : 8);
    const start = extra[i] ?? valueAt;
    if (extra[i] !== null) {
      if (big) view.setBigUint64(valueAt, BigInt(extra[i]), little);
      else view.setUint32(valueAt, extra[i], little);
    }
    actual.forEach((value, j) => put(type, start + j * sizes[type], value));
  });
  blocks.forEach((b, i) => out.set(b, blockOffsets[i]));
  return out;
}

const grid = (width, height) => Float32Array.from({ length: width * height }, (_, i) => 50 + (i % width) * 0.25 - Math.floor(i / width) * 0.5);

test('TIFF reader decodes strips, tiles, deflate/LZW and the floating-point predictor', async () => {
  const width = 5, height = 4, values = grid(width, height);
  for (const layout of [{}, { little: false }, { compression: 8, predictor: 3, tile: 3 },
    { compression: 8, predictor: 3, tile: 3, little: false }, { compression: 5 },
    { big: true, compression: 5, tile: 3 }, { big: true, little: false, compression: 8, predictor: 3 }]) {
    const raster = await decodeTiff(await buildTiff({ width, height, values, metadata: '<GDALMetadata/>', ...layout }));
    assert.equal(raster.width, width); assert.equal(raster.height, height);
    assert.deepEqual(Array.from(raster.data), Array.from(values), JSON.stringify(layout));
    assert.deepEqual(raster.tiepoint, [0, 0, 0, 12, 57, 0]); assert.equal(raster.metadata, '<GDALMetadata/>');
  }
  const repeated = new Uint8Array(40).fill(7);
  assert.deepEqual(Array.from(decodeLZW(lzwEncode(repeated), 40)), Array.from(repeated));
});

test('TIFF reader rejects non-TIFF, multi-band and unsupported compression', async () => {
  await assert.rejects(decodeTiff(new Uint8Array(16)));
  await assert.rejects(decodeTiff(await buildTiff({ width: 2, height: 2, values: grid(2, 2), bands: 2 })));
  await assert.rejects(decodeTiff(await buildTiff({ width: 2, height: 2, values: grid(2, 2), compression: 7 })));
});

test('course rectangle adds a 75 m margin; tiles are deterministic, ≤2500 px and capped', async () => {
  const coordinates = [{ latitude: '57.62', longitude: '12.00' }, { latitude: 57.63, longitude: 12.02 }, { latitude: 'x' }];
  const bounds = courseBounds(coordinates);
  assert.ok(Math.abs((57.62 - bounds.bottom) * 111320 - 75) < 0.1);
  assert.equal(courseBounds([]), null);
  assert.equal(courseBounds([{ latitude: 0, longitude: 179.9 }, { latitude: 0, longitude: -179.9 }]), null);
  const tiles = await terrainTiles(bounds);
  assert.equal(tiles.length, 1);
  assert.ok(tiles[0].width > 1300 && tiles[0].width < 1400 && tiles[0].height > 1250 && tiles[0].height < 1300);
  assert.deepEqual(await terrainTiles(bounds), tiles);
  const wide = await terrainTiles({ left: 12, right: 12.05, bottom: 57.62, top: 57.63 });
  assert.equal(wide.length, 2);
  assert.ok(wide.every(t => t.width <= 2500 && t.height <= 2500));
  assert.equal(wide[0].right, wide[1].left);
  assert.equal(await terrainTiles({ left: 12, right: 12.1, bottom: 57.6, top: 57.65 }), null);
});

test('packed grid round-trips to centimetres with a fixed header', async () => {
  const width = 7, height = 3, data = grid(width, height);
  const bounds = { left: 12, right: 12.001, bottom: 57, top: 57.001 };
  const { bytes, sha256 } = await packGrid({ width, height, data, bounds });
  assert.equal(sha256, sha(bytes));
  const header = new DataView(bytes.buffer, bytes.byteOffset, 64);
  assert.equal(String.fromCharCode(...bytes.subarray(0, 4)), 'PTTR');
  assert.equal(header.getUint16(4, true), 1);
  assert.equal(header.getUint32(8, true), width); assert.equal(header.getUint32(12, true), height);
  assert.deepEqual([0, 1, 2, 3].map(i => header.getFloat64(16 + i * 8, true)), [12, 12.001, 57, 57.001]);
  const base = header.getFloat64(48, true), scale = header.getFloat64(56, true);
  const body = new DataView((await decompress(bytes.subarray(64), 'deflate-raw')).buffer);
  for (let y = 0; y < height; y++) {
    let value = 0;
    for (let x = 0; x < width; x++) {
      value = (value + body.getUint16((y * width + x) * 2, true)) & 0xffff;
      assert.ok(Math.abs(base + value * scale - data[y * width + x]) < 0.006);
    }
  }
  await assert.rejects(packGrid({ width: 2, height: 1, data: [0, 7000], bounds }), { code: 'invalid_provider_response' });
});

const tile = { left: 12, right: 12.0005, bottom: 57, top: 57.0004, width: 30, height: 40 };
const tileTiff = () => buildTiff({ width: tile.width, height: tile.height, values: grid(tile.width, tile.height),
  compression: 8, predictor: 3, tile: 16, scale: [0.0005 / 30, 0.0004 / 40, 0], tiepoint: [0, 0, 0, 12, 57.0004, 0],
  metadata: '<GDALMetadata><Item name="gpxz-capture-date-min">2018-04-01</Item><Item name="gpxz-capture-date-max">2020-09-30</Item></GDALMetadata>' });

test('GPXZ raster request uses exact bounds/size and validates the returned grid', async () => {
  const bytes = await tileTiff();
  let calls = 0;
  const providers = new Providers({ providers: { gpxz: { key: 'gpxz-fixture-key' } } }, { fetchImpl: async (url, options) => {
    calls++;
    assert.equal(String(url), 'https://api.gpxz.io/v1/elevation/raster?bbox_left=12&bbox_right=12.0005&bbox_bottom=57'
      + '&bbox_top=57.0004&width_px=30&height_px=40&bathymetry=false');
    assert.deepEqual(options.headers, { 'x-api-key': 'gpxz-fixture-key', Accept: 'image/tiff' });
    assert.equal(options.redirect, 'error');
    return new Response(bytes, { headers: { 'x-data-sources': 'sweden_1m_dtm, bad source,copernicus_30m',
      'x-dataset-version': '2025.1' } });
  } });
  const raster = await providers.elevationRaster(tile);
  assert.equal(calls, 1);
  assert.deepEqual(raster.sources, ['sweden_1m_dtm', 'copernicus_30m']);
  assert.equal(raster.datasetVersion, '2025.1');
  assert.equal(raster.captureDateMin, '2018-04-01'); assert.equal(raster.captureDateMax, '2020-09-30');
  assert.equal(raster.grid.length, 1200);
  const lenient = new Providers({ providers: { gpxz: { key: 'k' } } }, { fetchImpl: async () => new Response(bytes) });
  for (const wrong of [{ ...tile, width: 31 }, { ...tile, left: 11.99 }]) {
    await assert.rejects(lenient.elevationRaster(wrong), { code: 'invalid_provider_response', providerWide: false });
  }
  const junk = new Providers({ providers: { gpxz: { key: 'k' } } }, { fetchImpl: async () => new Response('not a tiff') });
  await assert.rejects(junk.elevationRaster(tile), { code: 'invalid_provider_response', providerWide: false });
});

const coordinates = { courseID: 'A', coordinates: [{ poi: 1, hole: 1, latitude: 57.62, longitude: 12.0 },
  { poi: 2, hole: 1, latitude: 57.621, longitude: 12.001 }] };
const detail = { courseID: 'A', courseName: 'Å Links' };

function bundleFixture({ gpxzClaim = () => ({ status: 'CLAIMED', token: TOKEN }), upload, raster } = {}) {
  const calls = [], uploads = [], sends = [];
  const handler = createHandler({
    authenticate: async () => ({ id: UID }),
    providers: { configured: { golf: true, gpxz: true },
      async golf() { throw new Error('golf must be cached'); },
      async elevationRaster(t) {
        sends.push(t);
        return raster ?? { grid: grid(t.width, t.height), sources: ['fixture_1m'], datasetVersion: 'gpxz-v1',
          captureDateMin: null, captureDateMax: '2020-01-01' };
      } },
    storage: { async upload(path, bytes) { if (upload) await upload(); uploads.push([path, bytes]); } },
    rpc: async (name, args) => {
      calls.push([name, args]);
      if (name !== 'pintheory_data_claim') return true;
      if (args.p_key === 'golf:v1:detail:A') return { status: 'HIT', body: detail };
      if (args.p_key === 'golf:v1:coordinates:A') return { status: 'HIT', body: coordinates };
      return gpxzClaim(args);
    } });
  return { handler, calls, uploads, sends };
}

test('course bundle fetches, packs, stores and commits each terrain tile once, then serves cache hits', async () => {
  const first = bundleFixture();
  const res = await first.handler(request('/api/v1/golf/courses/A/bundle'));
  assert.equal(res.status, 200); assert.equal(res.headers.get('cache-control'), 'no-store');
  const body = await res.json();
  assert.deepEqual(body.detail, detail); assert.deepEqual(body.coordinates, coordinates);
  assert.equal(body.terrain.status, 'ready'); assert.equal(body.terrain.tiles.length, 1);
  const [ready] = body.terrain.tiles;
  assert.equal(first.sends.length, 1); assert.equal(first.uploads.length, 1);
  const [path, bytes] = first.uploads[0];
  assert.equal(path, `${ready.sha256}.pttr`); assert.equal(sha(bytes), ready.sha256);
  assert.deepEqual(ready.sources, ['fixture_1m']); assert.equal(ready.datasetVersion, 'gpxz-v1');
  const claim = first.calls.find(([name, args]) => name === 'pintheory_data_claim' && args.p_provider === 'gpxz');
  assert.equal(claim[1].p_key, `gpxz:raster:v1:${ready.id}`); assert.equal(claim[1].p_cache_only, false);
  const finish = first.calls.find(([name]) => name === 'pintheory_data_finish')[1];
  assert.deepEqual(finish.p_metadata, { courseID: 'A' });
  assert.equal(finish.p_body.format, 'pttr-v1'); assert.equal(finish.p_body.storagePath, path);

  const cached = bundleFixture({ gpxzClaim: () => ({ status: 'HIT', body: finish.p_body, fetchedAt: '2026-11-01T00:00:00Z' }) });
  const again = await (await cached.handler(request('/api/v1/golf/courses/A/bundle'))).json();
  assert.equal(again.terrain.tiles[0].sha256, ready.sha256);
  assert.equal(cached.sends.length, 0); assert.equal(cached.uploads.length, 0);
  assert.deepEqual(cached.calls.find(([name]) => name === 'pintheory_data_tag')[1],
    { p_key: `gpxz:raster:v1:${ready.id}`, p_course_id: 'A' });
});

test('terrain problems never block the course and never retry paid calls', async () => {
  for (const [status, code, state] of [['DISABLED', 'provider_disabled', 'unavailable'],
    ['BUDGET', 'daily_budget_exceeded', 'unavailable'], ['PENDING', 'request_pending', 'pending']]) {
    const f = bundleFixture({ gpxzClaim: () => ({ status }) });
    const res = await f.handler(request('/api/v1/golf/courses/A/bundle'));
    assert.equal(res.status, 200);
    const { terrain } = await res.json();
    assert.equal(terrain.status, state); assert.equal(terrain.tiles[0].code, code); assert.equal(f.sends.length, 0);
  }
  const storageDown = bundleFixture({ upload: async () => { throw new Error('storage offline'); } });
  const { terrain } = await (await storageDown.handler(request('/api/v1/golf/courses/A/bundle'))).json();
  assert.equal(terrain.tiles[0].code, 'storage_unavailable');
  const fail = storageDown.calls.find(([name]) => name === 'pintheory_data_fail')[1];
  assert.equal(fail.p_provider_wide, false); assert.equal(fail.p_retry_after, 300);
  assert.equal(storageDown.calls.some(([name]) => name === 'pintheory_data_finish'), false);
});

test('terrain download is cache-only, account-gated, rate-limited and checksum-verified', async () => {
  const bytes = new Uint8Array([1, 2, 3]);
  const id = 'a'.repeat(64);
  const run = async (claim, stored = bytes, allowance = { status: 'OK' }) => {
    const calls = [];
    const handler = createHandler({ authenticate: async () => ({ id: UID }),
      providers: { configured: { golf: true, gpxz: true } },
      storage: { async download(path, limit) { calls.push(['download', path, limit]); return stored; } },
      rpc: async (name, args) => { calls.push([name, args]); return name === 'pintheory_data_download' ? allowance : claim; } });
    return { res: await handler(request(`/api/v1/golf/terrain/${id}`)), calls };
  };
  const body = { format: 'pttr-v1', sha256: sha(bytes), storagePath: `${sha(bytes)}.pttr`, bytes: bytes.length };
  const ok = await run({ status: 'HIT', body });
  assert.equal(ok.res.status, 200); assert.equal(ok.res.headers.get('content-type'), 'application/octet-stream');
  assert.deepEqual(new Uint8Array(await ok.res.arrayBuffer()), bytes);
  assert.equal(ok.calls[0][1].p_key, `gpxz:raster:v1:${id}`); assert.equal(ok.calls[0][1].p_cache_only, true);
  assert.deepEqual(ok.calls[1], ['pintheory_data_download', { p_user_id: UID, p_bytes: bytes.length }]);
  assert.equal(ok.calls[2][1], body.storagePath);
  const limited = await run({ status: 'HIT', body }, bytes, { status: 'RATE_LIMIT', retryAfter: 600 });
  assert.equal(limited.res.status, 429); assert.equal(limited.res.headers.get('retry-after'), '600');
  assert.equal(limited.calls.some(([name]) => name === 'download'), false);
  assert.equal((await run({ status: 'HIT', body: { ...body, bytes: undefined } })).res.status, 503);
  assert.equal((await run({ status: 'HIT', body }, new Uint8Array([9]))).res.status, 503);
  assert.equal((await run({ status: 'CACHE_MISS' })).res.status, 404);
  assert.equal((await run({ status: 'FORBIDDEN' })).res.status, 403);
  assert.equal((await run({ status: 'HIT', body: { ...body, storagePath: '../x' } })).res.status, 503);
});

// SWEREF 99 TM sheet 639_32 corners from Lantmäteriet's STAC geometry (cross-checked with PROJ).
test('SWEREF 99 TM projection matches Lantmäteriet sheet corners', () => {
  for (const [lat, lon, east, north] of [[57.61637159471741, 11.986352857012228, 320000, 6390000],
    [57.70607237387218, 11.978898992365227, 320000, 6400000], [57.620249220767846, 12.1535347738668, 330000, 6390000]]) {
    const p = toSweref99TM(lat, lon);
    assert.ok(Math.abs(p.east - east) < 0.05 && Math.abs(p.north - north) < 0.05, JSON.stringify(p));
  }
});

const SHEET = { west: 320000, south: 6390000, east: 320064, north: 6390064 };
const plane = (e, n) => 100 + 0.01 * (e - SHEET.west) + 0.02 * (SHEET.north - n);
const sheetTiff = () => buildTiff({ width: 64, height: 64, tile: 16, compression: 8, predictor: 3,
  values: Float32Array.from({ length: 64 * 64 }, (_, i) => plane(SHEET.west + (i % 64) + 0.5, SHEET.north - Math.floor(i / 64) - 0.5)) });
const stacBody = (sheet = SHEET, href = 'https://dl1.lantmateriet.se/hojd/data/grid/mhm/63_3/m639_32.tif') => ({ features: [{
  id: '639_32', properties: { start_datetime: '2019-11-29T00:00:00Z', end_datetime: '2026-04-24T00:00:00Z', updated: '2026-09-23T02:00:22Z' },
  assets: { data: { href, 'proj:bbox': [sheet.west, sheet.south, sheet.east, sheet.north],
    'proj:transform': [1, 0, sheet.west, 0, -1, sheet.north, 0, 0, 1] } } }] });
const lmTile = { left: 11.98642, right: 11.98705, bottom: 57.61641, top: 57.61685, width: 30, height: 40, id: 'b'.repeat(64) };

test('STAC coverage requires every tile edge inside a 1 m sheet and validates asset URLs', () => {
  assert.equal(coveringItems(stacBody(), lmTile).length, 1);
  assert.deepEqual(coveringItems(stacBody({ ...SHEET, east: 320020 }), lmTile), []);
  assert.throws(() => coveringItems(stacBody(SHEET, 'https://evil.example/m.tif'), lmTile), { code: 'invalid_provider_response' });
});

test('Lantmäteriet grid reads only needed COG blocks with Basic auth and resamples onto the tile', async () => {
  const bytes = await sheetTiff();
  const ranges = [];
  const providers = new Providers({ providers: { lantmateriet: { username: 'user@example.se', password: 'påss' } } },
    { fetchImpl: async (url, options) => {
      assert.equal(String(url), 'https://dl1.lantmateriet.se/hojd/data/grid/mhm/63_3/m639_32.tif');
      assert.equal(options.headers.Authorization, `Basic ${Buffer.from('user@example.se:påss').toString('base64')}`);
      const [, start, end] = /^bytes=(\d+)-(\d+)$/.exec(options.headers.Range).map(Number);
      ranges.push([start, end]);
      return new Response(bytes.subarray(start, Math.min(end + 1, bytes.length)), { status: 206 });
    } });
  assert.equal(providers.configured.lantmateriet, true);
  const items = coveringItems(stacBody(), lmTile);
  // Small fixture: the 128 KB header request returns the whole file, so the length check is relaxed here.
  const raster = await lantmaterietGrid(lmTile, items, async (href, start, end) => {
    ranges.push([start, end]);
    return bytes.subarray(start, Math.min(end + 1, bytes.length));
  });
  assert.equal(raster.grid.length, 30 * 40);
  assert.deepEqual(raster.sources, ['lantmateriet_markhojdmodell']);
  assert.equal(raster.captureDateMin, '2019-11-29'); assert.equal(raster.datasetVersion, '2026-09-23');
  for (const [x, y] of [[0, 0], [15, 20], [29, 39]]) {
    const p = toSweref99TM(lmTile.top - (y + 0.5) * (lmTile.top - lmTile.bottom) / 40,
      lmTile.left + (x + 0.5) * (lmTile.right - lmTile.left) / 30);
    assert.ok(Math.abs(raster.grid[y * 30 + x] - plane(p.east, p.north)) < 0.01);
  }
  assert.ok(ranges.length < 1 + 16, 'only blocks overlapping the tile are read');
  await assert.rejects(new Providers({ providers: { lantmateriet: { username: 'u', password: 'p' } } },
    { fetchImpl: async () => { throw new TypeError('network'); } }).elevationLantmateriet(lmTile, items),
    { code: 'provider_unavailable', ambiguous: false, providerWide: false });
});

test('Swedish courses use Lantmäteriet tiles; elsewhere or outside coverage they use GPXZ', async () => {
  const run = async (country, items) => {
    const calls = [], sources = [];
    const handler = createHandler({ authenticate: async () => ({ id: UID }),
      providers: { configured: { golf: true, gpxz: true, lantmateriet: true },
        async lantmaterietItems() { return items; },
        async elevationLantmateriet(t) { sources.push('lm'); return { grid: grid(t.width, t.height), sources: ['lantmateriet_markhojdmodell'] }; },
        async elevationRaster(t) { sources.push('gpxz'); return { grid: grid(t.width, t.height), sources: ['gpxz_terrain_30m'] }; } },
      storage: { async upload() {} },
      rpc: async (name, args) => {
        calls.push([name, args]);
        if (name !== 'pintheory_data_claim') return true;
        if (args.p_key === 'golf:v1:detail:A') return { status: 'HIT', body: { ...detail, country } };
        if (args.p_key === 'golf:v1:coordinates:A') return { status: 'HIT', body: coordinates };
        return { status: 'CLAIMED', token: TOKEN };
      } });
    const { terrain } = await (await handler(request('/api/v1/golf/courses/A/bundle'))).json();
    const claim = calls.find(([name, args]) => name === 'pintheory_data_claim' && !args.p_key.startsWith('golf:'))[1];
    return { terrain, claim, sources, finish: calls.find(([name]) => name === 'pintheory_data_finish')[1] };
  };
  const swedish = await run('Sweden', [{ id: '639_32' }]);
  assert.deepEqual(swedish.sources, ['lm']);
  assert.equal(swedish.claim.p_provider, 'lantmateriet'); assert.match(swedish.claim.p_key, /^lm:dtm:v1:[a-f0-9]{64}$/);
  assert.equal(swedish.terrain.tiles[0].source, 'lantmateriet'); assert.equal(swedish.terrain.tiles[0].verticalDatum, 'RH2000');
  assert.equal(swedish.finish.p_body.verticalDatum, 'RH2000');
  for (const [country, items] of [['Norway', [{ id: 'x' }]], ['Sweden', []]]) {
    const other = await run(country, items);
    assert.deepEqual(other.sources, ['gpxz']); assert.equal(other.claim.p_provider, 'gpxz');
    assert.equal(other.terrain.tiles[0].verticalDatum, 'EGM2008');
  }
});

test('terrain download route selects the Lantmäteriet cache by path', async () => {
  const bytes = new Uint8Array([4, 5]);
  const calls = [];
  const handler = createHandler({ authenticate: async () => ({ id: UID }), providers: { configured: {} },
    storage: { async download() { return bytes; } },
    rpc: async (name, args) => { calls.push(args); return name === 'pintheory_data_download' ? { status: 'OK' } : { status: 'HIT',
      body: { format: 'pttr-v1', sha256: sha(bytes), storagePath: `${sha(bytes)}.pttr`, bytes: bytes.length } }; } });
  assert.equal((await handler(request(`/api/v1/golf/terrain/lm/${'c'.repeat(64)}`))).status, 200);
  assert.deepEqual([calls[0].p_provider, calls[0].p_key], ['lantmateriet', `lm:dtm:v1:${'c'.repeat(64)}`]);
});
