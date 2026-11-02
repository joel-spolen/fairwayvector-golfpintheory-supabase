import { APIError } from './errors.js';
import { blockRows, decodeBlock, readTiffLayout } from './tiff.js';

// Markhöjdmodell (dtm-cog): 10 × 10 km COG sheets in SWEREF 99 TM metres, RH 2000 heights.
export const LANTMATERIET_STAC = 'https://api.lantmateriet.se/stac-hojd/v1/search';
const ASSET = /^https:\/\/dl1\.lantmateriet\.se\/hojd\/data\/grid\/mhm\/[0-9_]{1,20}\/m[0-9_]{1,20}\.tif$/;
export const HEADER_BYTES = 131072;
const BLOCK_CONCURRENCY = 6;
const PROJECTION_STEP = 16;
const MAX_MISSING_FRACTION = 0.25;

const invalid = () => {
  const error = new APIError(502, 'invalid_provider_response', 'Provider returned invalid data.');
  error.providerWide = false;
  throw error;
};

// Lantmäteriet's Gauss–Krüger formulas for GRS 80 / SWEREF 99 TM (EPSG:3006).
const A = 6378137, F = 1 / 298.257222101, K0 = 0.9996, LON0 = 15 * Math.PI / 180, FALSE_EASTING = 500000;
const E2 = F * (2 - F), N = F / (2 - F);
const AROOF = A / (1 + N) * (1 + N ** 2 / 4 + N ** 4 / 64);
const CA = E2, CB = (5 * E2 ** 2 - E2 ** 3) / 6, CC = (104 * E2 ** 3 - 45 * E2 ** 4) / 120, CD = 1237 * E2 ** 4 / 1260;
const B1 = N / 2 - 2 * N ** 2 / 3 + 5 * N ** 3 / 16 + 41 * N ** 4 / 180;
const B2 = 13 * N ** 2 / 48 - 3 * N ** 3 / 5 + 557 * N ** 4 / 1440;
const B3 = 61 * N ** 3 / 240 - 103 * N ** 4 / 140;
const B4 = 49561 * N ** 4 / 161280;

export function toSweref99TM(lat, lon) {
  const phi = lat * Math.PI / 180, dl = lon * Math.PI / 180 - LON0;
  const s = Math.sin(phi), s2 = s * s;
  const phiStar = phi - s * Math.cos(phi) * (CA + s2 * (CB + s2 * (CC + s2 * CD)));
  const xi = Math.atan(Math.tan(phiStar) / Math.cos(dl));
  const eta = Math.atanh(Math.cos(phiStar) * Math.sin(dl));
  const north = K0 * AROOF * (xi + B1 * Math.sin(2 * xi) * Math.cosh(2 * eta) + B2 * Math.sin(4 * xi) * Math.cosh(4 * eta)
    + B3 * Math.sin(6 * xi) * Math.cosh(6 * eta) + B4 * Math.sin(8 * xi) * Math.cosh(8 * eta));
  const east = K0 * AROOF * (eta + B1 * Math.cos(2 * xi) * Math.sinh(2 * eta) + B2 * Math.cos(4 * xi) * Math.sinh(4 * eta)
    + B3 * Math.cos(6 * xi) * Math.sinh(6 * eta) + B4 * Math.cos(8 * xi) * Math.sinh(8 * eta)) + FALSE_EASTING;
  return { east, north };
}

/**
 * SWEREF coordinates of pixel centres on a coarse node grid (every PROJECTION_STEP px plus the
 * last row/column); pixels in between are interpolated bilinearly, i.e. convex combinations of nodes.
 */
function projectNodes(tile) {
  const { width, height } = tile;
  const dx = (tile.right - tile.left) / width, dy = (tile.top - tile.bottom) / height;
  const nodesX = Math.ceil((width - 1) / PROJECTION_STEP) + 1, nodesY = Math.ceil((height - 1) / PROJECTION_STEP) + 1;
  const nodeE = new Float64Array(nodesX * nodesY), nodeN = new Float64Array(nodesX * nodesY);
  const nodeAt = (k, size) => Math.min(k * PROJECTION_STEP, size - 1);
  for (let j = 0; j < nodesY; j++) {
    for (let i = 0; i < nodesX; i++) {
      const p = toSweref99TM(tile.top - (nodeAt(j, height) + 0.5) * dy, tile.left + (nodeAt(i, width) + 0.5) * dx);
      nodeE[j * nodesX + i] = p.east; nodeN[j * nodesX + i] = p.north;
    }
  }
  // Per column: left node index, right node index and interpolation weight.
  const columnI = new Int32Array(width), columnI1 = new Int32Array(width), columnT = new Float64Array(width);
  for (let x = 0; x < width; x++) {
    const i = nodesX > 1 ? Math.min(Math.floor(x / PROJECTION_STEP), nodesX - 2) : 0, i1 = Math.min(i + 1, nodesX - 1);
    const x0 = nodeAt(i, width), x1 = nodeAt(i1, width);
    columnI[x] = i; columnI1[x] = i1; columnT[x] = x1 > x0 ? (x - x0) / (x1 - x0) : 0;
  }
  const rowE = new Float64Array(nodesX), rowN = new Float64Array(nodesX);
  /** Fills rowE/rowN with node coordinates interpolated to pixel row y. */
  const row = (y) => {
    const j = nodesY > 1 ? Math.min(Math.floor(y / PROJECTION_STEP), nodesY - 2) : 0, j1 = Math.min(j + 1, nodesY - 1);
    const y0 = nodeAt(j, height), y1 = nodeAt(j1, height), ty = y1 > y0 ? (y - y0) / (y1 - y0) : 0;
    for (let i = 0; i < nodesX; i++) {
      const a = j * nodesX + i, c = j1 * nodesX + i;
      rowE[i] = nodeE[a] + (nodeE[c] - nodeE[a]) * ty; rowN[i] = nodeN[a] + (nodeN[c] - nodeN[a]) * ty;
    }
  };
  return { nodeE, nodeN, columnI, columnI1, columnT, rowE, rowN, row };
}

/** STAC sheets covering the whole tile, or [] when Lantmäteriet does not cover all of it. */
export function coveringItems(body, tile) {
  if (!body || !Array.isArray(body.features)) invalid();
  const items = body.features.map(feature => {
    const asset = feature?.assets?.data;
    const [e0, n0, e1, n1] = asset?.['proj:bbox'] ?? [];
    const transform = asset?.['proj:transform'] ?? [];
    if (!ASSET.test(asset?.href ?? '') || ![e0, n0, e1, n1].every(Number.isFinite)
        || transform[0] !== 1 || transform[4] !== -1 || transform[2] !== e0 || transform[5] !== n1) invalid();
    const date = value => typeof value === 'string' && /^\d{4}-\d\d-\d\d/.test(value) ? value.slice(0, 10) : null;
    const p = feature.properties ?? {};
    return { id: String(feature.id), href: asset.href, west: e0, south: n0, east: e1, north: n1,
      width: Math.round(e1 - e0), height: Math.round(n1 - n0),
      captureDateMin: date(p.start_datetime), captureDateMax: date(p.end_datetime), updated: date(p.updated) };
  });
  const inside = (e, n) => items.some(item => e >= item.west + 1 && e <= item.east - 1 && n >= item.south + 1 && n <= item.north - 1);
  for (const [lat, lon] of [[tile.top, tile.left], [tile.top, tile.right], [tile.bottom, tile.left], [tile.bottom, tile.right],
    [(tile.top + tile.bottom) / 2, tile.left], [(tile.top + tile.bottom) / 2, tile.right],
    [tile.top, (tile.left + tile.right) / 2], [tile.bottom, (tile.left + tile.right) / 2]]) {
    const p = toSweref99TM(lat, lon);
    if (!inside(p.east, p.north)) return [];
  }
  return items;
}

async function mapLimited(values, limit, work) {
  const results = new Array(values.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, values.length) }, async () => {
    while (next < values.length) { const i = next++; results[i] = await work(values[i]); }
  }));
  return results;
}

/**
 * Resamples the 1 m SWEREF grid onto the tile's lat/lon grid, reading only the COG blocks needed.
 * `fetchRange(href, start, end)` returns exactly that byte range.
 */
export async function lantmaterietGrid(tile, items, fetchRange) {
  const projection = projectNodes(tile);
  const { nodeE, nodeN } = projection;
  let tileMinE = Infinity, tileMaxE = -Infinity, tileMinN = Infinity, tileMaxN = -Infinity;
  for (let k = 0; k < nodeE.length; k++) {
    tileMinE = Math.min(tileMinE, nodeE[k]); tileMaxE = Math.max(tileMaxE, nodeE[k]);
    tileMinN = Math.min(tileMinN, nodeN[k]); tileMaxN = Math.max(tileMaxN, nodeN[k]);
  }
  const windows = [];
  for (const item of items) {
    // Every pixel lies within the node bounding box, so this clip covers all pixels in the sheet.
    const minE = Math.max(tileMinE, item.west), maxE = Math.min(tileMaxE, item.east);
    const minN = Math.max(tileMinN, item.south), maxN = Math.min(tileMaxN, item.north);
    if (minE > maxE || minN > maxN) continue;
    const layout = readTiffLayout(await fetchRange(item.href, 0, HEADER_BYTES - 1));
    if (layout.width !== item.width || layout.height !== item.height || !layout.tiled) invalid();
    const { blockWidth: bw, blockHeight: bh } = layout;
    const clamp = (v, max) => Math.min(Math.max(v, 0), max);
    const bx0 = clamp(Math.floor((minE - item.west - 2) / bw), layout.across - 1);
    const bx1 = clamp(Math.floor((maxE - item.west + 2) / bw), layout.across - 1);
    const by0 = clamp(Math.floor((item.north - maxN - 2) / bh), layout.down - 1);
    const by1 = clamp(Math.floor((item.north - minN + 2) / bh), layout.down - 1);
    const window = { item, nodata: layout.nodata, c0: bx0 * bw, r0: by0 * bh,
      w: (bx1 - bx0 + 1) * bw, h: (by1 - by0 + 1) * bh };
    window.data = new Float32Array(window.w * window.h).fill(NaN);
    const blocks = [];
    for (let by = by0; by <= by1; by++) for (let bx = bx0; bx <= bx1; bx++) blocks.push({ bx, by });
    await mapLimited(blocks, BLOCK_CONCURRENCY, async ({ bx, by }) => {
      const index = by * layout.across + bx, start = layout.offsets[index], length = layout.counts[index];
      if (!(length > 0)) return;
      const rows = blockRows(layout, by);
      const values = await decodeBlock(layout, await fetchRange(item.href, start, start + length - 1), rows);
      for (let r = 0; r < rows; r++) {
        window.data.set(values.subarray(r * bw, (r + 1) * bw), (by * bh - window.r0 + r) * window.w + (bx * bw - window.c0));
      }
    });
    windows.push(window);
  }

  const { width, height } = tile;
  const { columnI, columnI1, columnT, rowE, rowN } = projection;
  const grid = new Float32Array(width * height);
  let missing = 0, window = windows[0];
  for (let y = 0; y < height; y++) {
    projection.row(y);
    for (let x = 0; x < width; x++) {
      const i = columnI[x], i1 = columnI1[x], tx0 = columnT[x];
      const e = rowE[i] + (rowE[i1] - rowE[i]) * tx0, n = rowN[i] + (rowN[i1] - rowN[i]) * tx0;
      if (!window || e < window.item.west || e > window.item.east || n < window.item.south || n > window.item.north) {
        window = windows.find(w => e >= w.item.west && e <= w.item.east && n >= w.item.south && n <= w.item.north);
      }
      let value = NaN;
      if (window) {
        // Pixel centres sit at west + col + 0.5 and north - row - 0.5.
        const ww = window.w, data = window.data, nodata = window.nodata;
        const fx = e - window.item.west - 0.5 - window.c0, fy = window.item.north - n - 0.5 - window.r0;
        const x0 = Math.min(Math.max(Math.floor(fx), 0), ww - 2), y0 = Math.min(Math.max(Math.floor(fy), 0), window.h - 2);
        const tx = Math.min(Math.max(fx - x0, 0), 1), ty = Math.min(Math.max(fy - y0, 0), 1);
        const at = y0 * ww + x0;
        const v00 = data[at], v10 = data[at + 1], v01 = data[at + ww], v11 = data[at + ww + 1];
        const w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty), w01 = (1 - tx) * ty, w11 = tx * ty;
        let sum = 0, weight = 0;
        // NaN marks blocks that were not stored; nodata marks sea and gaps.
        if (w00 > 0 && v00 === v00 && v00 !== nodata) { sum += v00 * w00; weight += w00; }
        if (w10 > 0 && v10 === v10 && v10 !== nodata) { sum += v10 * w10; weight += w10; }
        if (w01 > 0 && v01 === v01 && v01 !== nodata) { sum += v01 * w01; weight += w01; }
        if (w11 > 0 && v11 === v11 && v11 !== nodata) { sum += v11 * w11; weight += w11; }
        if (weight > 0) value = sum / weight;
      }
      if (Number.isNaN(value)) { missing++; value = 0; } // Sea and gaps: RH 2000 mean sea level.
      grid[y * width + x] = value;
    }
  }
  if (missing > grid.length * MAX_MISSING_FRACTION) invalid();
  const dates = (key) => items.map(item => item[key]).filter(Boolean).sort();
  return { grid, sources: ['lantmateriet_markhojdmodell'],
    captureDateMin: dates('captureDateMin')[0] ?? null, captureDateMax: dates('captureDateMax').at(-1) ?? null,
    datasetVersion: dates('updated').at(-1) ?? null };
}
