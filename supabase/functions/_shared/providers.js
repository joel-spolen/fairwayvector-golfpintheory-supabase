import { APIError } from './errors.js';
import { decodeTiff } from './tiff.js';
import { validPoint } from './geometry.js';
import { readBytes, readText, cancelBody, withDeadline } from './web.js';

const RASTER_BYTES_LIMIT = 60_000_000;

const invalid = () => {
  const error = new APIError(502, 'invalid_provider_response', 'Provider returned invalid data.');
  error.providerWide = false;
  throw error;
};
const object = value => value && typeof value === 'object' && !Array.isArray(value);
const text = value => (typeof value === 'string' || typeof value === 'number') && String(value).length > 0;
const numeric = value => (typeof value === 'number' || (typeof value === 'string' && value.trim() !== ''))
  && Number.isFinite(Number(value));

export function validateGolf(body, kind, id) {
  if (!object(body)) invalid();
  if (kind === 'clubs' || kind === 'courses') {
    if (!Array.isArray(body[kind]) || !body[kind].every(object)) invalid();
    for (const item of body[kind]) {
      if (!text(item[kind === 'clubs' ? 'clubID' : 'courseID'])
          || !text(item[kind === 'clubs' ? 'clubName' : 'courseName'])) invalid();
    }
  } else {
    if (!text(body.courseID) || String(body.courseID) !== id) invalid();
    // GolfAPI can leave a single-course club's course name empty. Preserve the
    // provider body; clients supply a display-name fallback, not a new identity.
    if (kind === 'detail' && typeof body.courseName !== 'string') invalid();
    if (kind === 'coordinates') {
      if (!Array.isArray(body.coordinates) || body.coordinates.length === 0) invalid();
      for (const point of body.coordinates) {
        if (!object(point) || !numeric(point.poi) || !numeric(point.hole)
            || !numeric(point.latitude) || !numeric(point.longitude)
            || !validPoint({ lat: Number(point.latitude), lon: Number(point.longitude) })) invalid();
      }
    }
  }
  // Account-wide remaining credit must not leak to clients or become stale cache metadata.
  const { apiRequestsLeft, ...data } = body;
  return data;
}

/** Exact requested size/bounds, finite plausible heights; GPXZ never returns gaps. */
export function validateRaster(raster, tile) {
  if (raster.width !== tile.width || raster.height !== tile.height) invalid();
  const [, , , x, y] = raster.tiepoint ?? [];
  const [sx, sy] = raster.pixelScale ?? [];
  if (![x, y, sx, sy].every(Number.isFinite) || sx <= 0 || sy <= 0
      || Math.abs(x - tile.left) > sx || Math.abs(y - tile.top) > sy
      || Math.abs(sx * tile.width - (tile.right - tile.left)) > sx
      || Math.abs(sy * tile.height - (tile.top - tile.bottom)) > sy) invalid();
  for (const value of raster.data) {
    if (!Number.isFinite(value) || value < -500 || value > 9000 || value === raster.nodata) invalid();
  }
  const date = name => {
    const match = new RegExp(`<Item name="${name}"[^>]*>([^<]{0,40})</Item>`).exec(raster.metadata ?? '');
    return match && /^\d{4}-\d\d-\d\d$/.test(match[1]) ? match[1] : null;
  };
  return { captureDateMin: date('gpxz-capture-date-min'), captureDateMax: date('gpxz-capture-date-max') };
}

export class Providers {
  constructor(config, { fetchImpl = globalThis.fetch, timeoutMs = 30000 } = {}) {
    this.config = config;
    this.fetch = fetchImpl;
    this.timeoutMs = timeoutMs;
    // DB settings alone enable paid acquisition; this only describes key availability.
    this.configured = Object.fromEntries(['golf', 'gpxz'].map(name =>
      [name, typeof config.providers?.[name]?.key === 'string' && !!config.providers[name].key.trim()]));
  }

  async request(url, options, binaryLimit = null) {
    try {
      return await withDeadline(this.timeoutMs, async signal => {
        const response = await this.fetch(url, { ...options, redirect: 'error', signal });
        if (signal.aborted || response.redirected) { cancelBody(response); throw new Error('Aborted or redirected'); }
        if (!response.ok) {
          const retry = response.headers.get('retry-after');
          const seconds = retry && /^\d+$/.test(retry) ? Number(retry)
            : Math.ceil((Date.parse(retry) - Date.now()) / 1000);
          cancelBody(response);
          const error = new APIError(502, 'provider_unavailable', 'Provider could not complete the request.',
            Number.isFinite(seconds) ? Math.max(1, Math.min(86400, seconds)) : undefined);
          error.ambiguous = false;
          error.providerWide = [401, 403, 429].includes(response.status) || response.status >= 500;
          throw error;
        }
        if (Number(response.headers.get('content-length')) > (binaryLimit ?? 4000000)) {
          cancelBody(response); throw new Error('Body too large');
        }
        const version = response.headers.get('x-dataset-version');
        const datasetVersion = version && /^[\x20-\x7e]{1,200}$/.test(version) ? version : null;
        if (binaryLimit) {
          const sources = (response.headers.get('x-data-sources') ?? '').split(',')
            .map(source => source.trim()).filter(source => /^[A-Za-z0-9_.-]{1,100}$/.test(source)).slice(0, 50);
          return { body: await readBytes(response.body, binaryLimit, signal), datasetVersion, sources };
        }
        return { body: JSON.parse(await readText(response.body, 4000000, signal)), datasetVersion };
      });
    } catch (error) {
      if (error instanceof APIError) throw error;
      // A missing/incomplete response does not prove the provider did not bill.
      const ambiguous = new APIError(502, 'provider_unavailable', 'Provider could not complete the request.');
      ambiguous.ambiguous = true;
      throw ambiguous;
    }
  }

  async golf(path, query, kind, id) {
    if (!this.configured.golf) throw new APIError(503, 'provider_not_configured', 'Provider is not configured.');
    const url = new URL(`https://golfapi.io/api/v2.3${path}`);
    for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value);
    const result = await this.request(url, { headers: {
      Authorization: `Bearer ${this.config.providers.golf.key}`, Accept: 'application/json'
    } });
    return { ...result, body: validateGolf(result.body, kind, id) };
  }

  async elevationRaster(tile) {
    if (!this.configured.gpxz) throw new APIError(503, 'provider_not_configured', 'Provider is not configured.');
    const url = new URL('https://api.gpxz.io/v1/elevation/raster');
    for (const [key, value] of Object.entries({ bbox_left: tile.left, bbox_right: tile.right,
      bbox_bottom: tile.bottom, bbox_top: tile.top, width_px: tile.width, height_px: tile.height,
      bathymetry: 'false' })) url.searchParams.set(key, String(value));
    const result = await this.request(url, { headers: {
      'x-api-key': this.config.providers.gpxz.key, Accept: 'image/tiff'
    } }, RASTER_BYTES_LIMIT);
    let raster;
    try { raster = await decodeTiff(result.body); } catch { invalid(); }
    return { ...validateRaster(raster, tile), grid: raster.data, sources: result.sources,
      datasetVersion: result.datasetVersion };
  }
}