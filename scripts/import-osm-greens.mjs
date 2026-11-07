import { createReadStream } from 'node:fs';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

const BATCH = 500;
const round7 = value => Math.round(value * 1e7) / 1e7;
const fail = message => { throw new Error(message); };

/** One catalog row per OpenStreetMap green; multipolygons keep their largest outer ring. */
export function greenRow(feature) {
  const type = feature?.properties?.['@type'];
  const id = Number(feature?.properties?.['@id']);
  const geometry = feature?.geometry;
  if (!['way', 'relation'].includes(type) || !Number.isSafeInteger(id) || id <= 0) return null;
  const outers = geometry?.type === 'Polygon' ? [geometry.coordinates?.[0]]
    : geometry?.type === 'MultiPolygon' ? (geometry.coordinates ?? []).map(polygon => polygon?.[0])
    : geometry?.type === 'LineString' ? [geometry.coordinates] : [];
  const rings = outers.filter(ring => Array.isArray(ring) && ring.length >= 4 && ring.length <= 2000
    && ring.every(p => Array.isArray(p) && Math.abs(p[0]) <= 180 && Math.abs(p[1]) <= 90));
  if (!rings.length) return null;
  const ring = rings.sort((a, b) => b.length - a.length)[0].map(([lon, lat]) => [round7(lat), round7(lon)]);
  const lats = ring.map(p => p[0]), lons = ring.map(p => p[1]);
  const row = { type, id, minLat: Math.min(...lats), minLon: Math.min(...lons),
    maxLat: Math.max(...lats), maxLon: Math.max(...lons), ring };
  // Larger "greens" are mapping mistakes (or whole courses) and would break the box search.
  return row.maxLat - row.minLat < 0.02 && row.maxLon - row.minLon < 0.04 ? row : null;
}

/** osmium `fileinfo -g header.boxes` prints "(minLon,minLat,maxLon,maxLat)". */
export function parseBounds(text) {
  const values = String(text).replace(/[()\s]/g, '').split(',').map(Number);
  if (values.length !== 4 || !values.every(Number.isFinite)) fail('Region bounds are required.');
  const [minLon, minLat, maxLon, maxLat] = values;
  if (minLat > maxLat || minLon > maxLon) fail('Region bounds are invalid.');
  return { minLat, minLon, maxLat, maxLon };
}

export async function importRegion({ region, file, bounds, projectRef, serviceKey, fetchImpl = fetch, log = console.log }) {
  if (!/^[a-z0-9-]+(\/[a-z0-9-]+)*$/.test(region ?? '')) fail('A Geofabrik region like europe/sweden is required.');
  if (!/^[a-z0-9]{20}$/.test(projectRef ?? '')) fail('SUPABASE_PROJECT_REF is required.');
  if (!serviceKey) fail('SUPABASE_SERVICE_ROLE_KEY is required.');
  const headers = { apikey: serviceKey, 'Content-Type': 'application/json', Accept: 'application/json',
    ...(serviceKey.startsWith('sb_secret_') ? {} : { Authorization: `Bearer ${serviceKey}` }) };
  // Surface bounded PostgREST diagnostics without echoing credentials or raw bodies.
  const rpc = async (name, body) => {
    const response = await fetchImpl(`https://${projectRef}.supabase.co/rest/v1/rpc/${name}`,
      { method: 'POST', headers, body: JSON.stringify(body), redirect: 'error', signal: AbortSignal.timeout(120000) });
    if (!response.ok) {
      let detail = '';
      try {
        const error = await response.json();
        const safe = value => typeof value === 'string' ? value.replace(/[\r\n\t]/g, ' ').slice(0, 240) : '';
        detail = [safe(error?.code), safe(error?.message), safe(error?.details)].filter(Boolean).join(': ');
      } catch { /* A gateway may return a non-JSON error. */ }
      fail(`${name} failed with HTTP ${response.status}${detail ? `: ${detail}` : ''}.`);
    }
    return response.json();
  };

  const startedAt = new Date().toISOString();
  log(`${region}: staging generation ${startedAt}`);
  let batch = [], total = 0;
  const lines = createInterface({ input: createReadStream(file, 'utf8'), crlfDelay: Infinity });
  for await (const line of lines) {
    const text = line.replace(/^\x1e/, '').trim();
    if (!text) continue;
    let feature;
    try { feature = JSON.parse(text); } catch { continue; }
    const row = greenRow(feature);
    if (!row) continue;
    batch.push(row);
    if (batch.length === BATCH) {
      total += await rpc('pintheory_osm_greens_import', { p_region: region, p_started_at: startedAt, p_rows: batch });
      log(`${region}: ${total} greens staged`);
      batch = [];
    }
  }
  if (batch.length) {
    total += await rpc('pintheory_osm_greens_import', { p_region: region, p_started_at: startedAt, p_rows: batch });
    log(`${region}: ${total} greens staged`);
  }
  // An empty or broken extract must never wipe the region's existing greens.
  if (total === 0) fail(`No greens found for ${region}; existing data kept.`);
  const kept = await rpc('pintheory_osm_greens_finish', { p_region: region, p_started_at: startedAt, p_greens: total,
    p_min_lat: bounds.minLat, p_min_lon: bounds.minLon, p_max_lat: bounds.maxLat, p_max_lon: bounds.maxLon });
  log(`${region}: activated ${kept} greens for generation ${startedAt}.`);
  try {
    let removed = 0, deleted;
    do {
      deleted = await rpc('pintheory_osm_greens_cleanup', { p_region: region, p_limit: 10000 });
      removed += deleted;
    } while (deleted === 10000);
    if (removed) log(`${region}: cleaned up ${removed} superseded rows.`);
  } catch (error) {
    log(`${region}: cleanup deferred; active generation is safe. ${error.message}`);
  }
  return { imported: total, kept };
}

export async function recoverRegion({ region, bounds, projectRef, serviceKey, fetchImpl = fetch, log = console.log }) {
  if (!/^[a-z0-9-]+(\/[a-z0-9-]+)*$/.test(region ?? '')) fail('A Geofabrik region like north-america/us is required.');
  if (!/^[a-z0-9]{20}$/.test(projectRef ?? '')) fail('SUPABASE_PROJECT_REF is required.');
  if (!serviceKey) fail('SUPABASE_SERVICE_ROLE_KEY is required.');
  const headers = { apikey: serviceKey, 'Content-Type': 'application/json', Accept: 'application/json',
    ...(serviceKey.startsWith('sb_secret_') ? {} : { Authorization: `Bearer ${serviceKey}` }) };
  const response = await fetchImpl(`https://${projectRef}.supabase.co/rest/v1/rpc/pintheory_osm_greens_recover`,
    { method: 'POST', headers, body: JSON.stringify({ p_region: region, p_min_lat: bounds.minLat, p_min_lon: bounds.minLon,
      p_max_lat: bounds.maxLat, p_max_lon: bounds.maxLon }), redirect: 'error', signal: AbortSignal.timeout(120000) });
  if (!response.ok) {
    let detail = '';
    try {
      const error = await response.json();
      const safe = value => typeof value === 'string' ? value.replace(/[\r\n\t]/g, ' ').slice(0, 240) : '';
      detail = [safe(error?.code), safe(error?.message), safe(error?.details)].filter(Boolean).join(': ');
    } catch { /* A gateway may return a non-JSON error. */ }
    fail(`pintheory_osm_greens_recover failed with HTTP ${response.status}${detail ? `: ${detail}` : ''}.`);
  }
  const startedAt = await response.json();
  log(`${region}: recovered and activated existing generation ${startedAt}; no extract was downloaded.`);
  return { startedAt };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [first, second, third] = process.argv.slice(2);
  const credentials = { projectRef: process.env.SUPABASE_PROJECT_REF, serviceKey: process.env.SUPABASE_SERVICE_ROLE_KEY };
  if (first === '--recover') {
    await recoverRegion({ region: second, bounds: parseBounds(third), ...credentials });
  } else {
    await importRegion({ region: first, file: second, bounds: parseBounds(third), ...credentials });
  }
}
