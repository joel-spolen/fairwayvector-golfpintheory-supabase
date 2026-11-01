import { APIError } from './errors.js';
import { validPoint } from './geometry.js';

// One GPXZ raster call covers at most 2500 × 2500 pixels.
export const RESOLUTION_METERS = 1;
const MAX_TILE_PIXELS = 2500;
const MAX_TOTAL_PIXELS = 8_000_000;
const MARGIN_METERS = 75;
const METERS_PER_DEGREE = 111_320;
const HEADER_BYTES = 64;
const round7 = value => Math.round(value * 1e7) / 1e7;
const metersPerLonDegree = (bottom, top) => METERS_PER_DEGREE * Math.cos((bottom + top) / 2 * Math.PI / 180);

export async function sha256Hex(bytes) {
  const digest = await globalThis.crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('');
}

async function deflateRaw(bytes) {
  const stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream('deflate-raw'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/** Rectangle around every course coordinate plus a margin, or null when unusable. */
export function courseBounds(coordinates) {
  const points = (Array.isArray(coordinates) ? coordinates : [])
    .map(p => ({ lat: Number(p?.latitude), lon: Number(p?.longitude) }))
    .filter(validPoint);
  if (!points.length) return null;
  const lats = points.map(p => p.lat), lons = points.map(p => p.lon);
  const south = Math.min(...lats), north = Math.max(...lats);
  const west = Math.min(...lons), east = Math.max(...lons);
  // Courses spanning the antimeridian or more than ~20 km are not supported.
  if (east - west > 0.5 || north - south > 0.2) return null;
  const dLat = MARGIN_METERS / METERS_PER_DEGREE;
  const dLon = MARGIN_METERS / metersPerLonDegree(south, north);
  return { left: round7(west - dLon), right: round7(east + dLon), bottom: round7(south - dLat), top: round7(north + dLat) };
}

/** Splits the course rectangle into ≤2500 px tiles at 1 m, north to south. Null when too large. */
export async function terrainTiles(bounds) {
  const lonMeters = metersPerLonDegree(bounds.bottom, bounds.top);
  const lonSpan = bounds.right - bounds.left, latSpan = bounds.top - bounds.bottom;
  const tileMeters = MAX_TILE_PIXELS * RESOLUTION_METERS;
  const across = Math.ceil(lonSpan * lonMeters / tileMeters), down = Math.ceil(latSpan * METERS_PER_DEGREE / tileMeters);
  const pixels = size => Math.min(MAX_TILE_PIXELS, Math.max(10, Math.ceil(size / RESOLUTION_METERS)));
  const tiles = [];
  for (let y = 0; y < down; y++) {
    for (let x = 0; x < across; x++) {
      const left = round7(bounds.left + lonSpan * x / across), right = round7(bounds.left + lonSpan * (x + 1) / across);
      const top = round7(bounds.top - latSpan * y / down), bottom = round7(bounds.top - latSpan * (y + 1) / down);
      const tile = { left, right, bottom, top,
        width: pixels((right - left) * lonMeters), height: pixels((top - bottom) * METERS_PER_DEGREE) };
      tile.id = await sha256Hex(new TextEncoder().encode(JSON.stringify({ ...tile, bathymetry: false })));
      tiles.push(tile);
    }
  }
  return tiles.reduce((sum, t) => sum + t.width * t.height, 0) > MAX_TOTAL_PIXELS ? null : tiles;
}

/**
 * PTTR v1: 64-byte little-endian header (magic, version, width, height, left, right,
 * bottom, top, base metres, metres per unit) + raw-deflated UInt16 rows (north first),
 * each row delta-encoded left to right modulo 65536.
 */
export async function packGrid({ width, height, data, bounds }) {
  let min = Infinity, max = -Infinity;
  for (const value of data) {
    if (!Number.isFinite(value)) throw invalidRaster();
    if (value < min) min = value;
    if (value > max) max = value;
  }
  const scale = max - min <= 655.35 ? 0.01 : max - min <= 6553.5 ? 0.1 : null;
  if (scale === null) throw invalidRaster();
  const body = new Uint8Array(width * height * 2);
  const view = new DataView(body.buffer);
  for (let y = 0; y < height; y++) {
    let previous = 0;
    for (let x = 0; x < width; x++) {
      const i = y * width + x;
      const quantized = Math.round((data[i] - min) / scale);
      view.setUint16(i * 2, (quantized - previous) & 0xffff, true);
      previous = quantized;
    }
  }
  const compressed = await deflateRaw(body);
  const packed = new Uint8Array(HEADER_BYTES + compressed.length);
  const header = new DataView(packed.buffer);
  packed.set([0x50, 0x54, 0x54, 0x52]); // "PTTR"
  header.setUint16(4, 1, true);
  header.setUint32(8, width, true);
  header.setUint32(12, height, true);
  [bounds.left, bounds.right, bounds.bottom, bounds.top, min, scale]
    .forEach((value, i) => header.setFloat64(16 + i * 8, value, true));
  packed.set(compressed, HEADER_BYTES);
  return { bytes: packed, sha256: await sha256Hex(packed) };
}

function invalidRaster() {
  const error = new APIError(502, 'invalid_provider_response', 'Provider returned invalid data.');
  error.providerWide = false;
  return error;
}
