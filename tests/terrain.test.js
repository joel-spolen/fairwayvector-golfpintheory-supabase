import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createHandler } from '../supabase/functions/golf-data/handler.js';
import { Providers } from '../supabase/functions/_shared/providers.js';
import { decodeTiff, decodeLZW } from '../supabase/functions/_shared/tiff.js';
import { courseBounds, terrainTiles, packGrid } from '../supabase/functions/_shared/terrain.js';

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
  scale = [0.00001, 0.00001, 0], tiepoint = [0, 0, 0, 12, 57, 0], metadata = null, bands = 1 }) {
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
  const sizes = { 2: 1, 3: 2, 4: 4, 12: 8 };
  const ifdSize = 2 + entries.length * 12 + 4;
  let dataOffset = 8 + ifdSize;
  const extra = entries.map(([, type, values]) => {
    const bytes = sizes[type] * values.length;
    if (bytes <= 4) return null;
    const at = dataOffset; dataOffset += bytes + (bytes % 2); return at;
  });
  const blockOffsets = blocks.map(b => { const at = dataOffset; dataOffset += b.length; return at; });
  const out = new Uint8Array(dataOffset);
  const view = new DataView(out.buffer);
  out.set(little ? [0x49, 0x49] : [0x4d, 0x4d]);
  view.setUint16(2, 42, little); view.setUint32(4, 8, little); view.setUint16(8, entries.length, little);
  const put = (type, at, value) => {
    if (type === 2) view.setUint8(at, value);
    else if (type === 3) view.setUint16(at, value, little);
    else if (type === 4) view.setUint32(at, value, little);
    else view.setFloat64(at, value, little);
  };
  entries.forEach(([tag, type, values], i) => {
    const entry = 10 + i * 12;
    const actual = tag === 324 || tag === 273 ? blockOffsets : values;
    view.setUint16(entry, tag, little); view.setUint16(entry + 2, type, little); view.setUint32(entry + 4, actual.length, little);
    const start = extra[i] ?? entry + 8;
    if (extra[i] !== null) view.setUint32(entry + 8, extra[i], little);
    actual.forEach((value, j) => put(type, start + j * sizes[type], value));
  });
  blocks.forEach((b, i) => out.set(b, blockOffsets[i]));
  return out;
}

const grid = (width, height) => Float32Array.from({ length: width * height }, (_, i) => 50 + (i % width) * 0.25 - Math.floor(i / width) * 0.5);

test('TIFF reader decodes strips, tiles, deflate/LZW and the floating-point predictor', async () => {
  const width = 5, height = 4, values = grid(width, height);
  for (const layout of [{}, { little: false }, { compression: 8, predictor: 3, tile: 3 },
    { compression: 8, predictor: 3, tile: 3, little: false }, { compression: 5 }]) {
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

test('terrain download is cache-only, account-gated and checksum-verified', async () => {
  const bytes = new Uint8Array([1, 2, 3]);
  const id = 'a'.repeat(64);
  const run = async (claim, stored = bytes) => {
    const calls = [];
    const handler = createHandler({ authenticate: async () => ({ id: UID }),
      providers: { configured: { golf: true, gpxz: true } },
      storage: { async download(path, limit) { calls.push(['download', path, limit]); return stored; } },
      rpc: async (name, args) => { calls.push([name, args]); return claim; } });
    return { res: await handler(request(`/api/v1/golf/terrain/${id}`)), calls };
  };
  const body = { format: 'pttr-v1', sha256: sha(bytes), storagePath: `${sha(bytes)}.pttr` };
  const ok = await run({ status: 'HIT', body });
  assert.equal(ok.res.status, 200); assert.equal(ok.res.headers.get('content-type'), 'application/octet-stream');
  assert.deepEqual(new Uint8Array(await ok.res.arrayBuffer()), bytes);
  assert.equal(ok.calls[0][1].p_key, `gpxz:raster:v1:${id}`); assert.equal(ok.calls[0][1].p_cache_only, true);
  assert.equal(ok.calls[1][1], body.storagePath);
  assert.equal((await run({ status: 'HIT', body }, new Uint8Array([9]))).res.status, 503);
  assert.equal((await run({ status: 'CACHE_MISS' })).res.status, 404);
  assert.equal((await run({ status: 'FORBIDDEN' })).res.status, 403);
  assert.equal((await run({ status: 'HIT', body: { ...body, storagePath: '../x' } })).res.status, 503);
});
