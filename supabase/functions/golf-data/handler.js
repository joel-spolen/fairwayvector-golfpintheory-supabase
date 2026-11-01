import { APIError } from '../_shared/errors.js';
import { courseBounds, packGrid, sha256Hex, terrainTiles, RESOLUTION_METERS } from '../_shared/terrain.js';

const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const invalid = () => { throw new APIError(400, 'invalid_request', 'Request rejected.'); };
const unavailable = () => new APIError(503, 'service_unavailable', 'Data service is temporarily unavailable.');
const own = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key);
const TERRAIN_DOWNLOAD_LIMIT = 64_000_000;

async function hash(value) {
  return sha256Hex(new TextEncoder().encode(value));
}

function parameters(search, allowed) {
  const values = Object.create(null);
  for (const [key, value] of search) {
    if (!allowed.includes(key) || own(values, key)) invalid();
    values[key] = value;
  }
  return values;
}

function golfDetail(collection, id) {
  const kind = collection === 'courses' ? 'detail' : 'coordinates';
  return { provider: 'golf', key: `golf:v1:${kind}:${id}`, maxAge: null, metadata: {},
    acquire: providers => providers.golf(`/${collection}/${id}`, {}, kind, id) };
}

function rasterTile(tile, courseID, storage) {
  return { provider: 'gpxz', key: `gpxz:raster:v1:${tile.id}`, maxAge: null, metadata: { courseID },
    acquire: async providers => {
      const raster = await providers.elevationRaster(tile);
      const bounds = { left: tile.left, right: tile.right, bottom: tile.bottom, top: tile.top };
      const packed = await packGrid({ width: tile.width, height: tile.height, data: raster.grid, bounds });
      const storagePath = `${packed.sha256}.pttr`;
      try { await storage.upload(storagePath, packed.bytes); }
      catch {
        // The paid response was received intact; record a definitive, retryable failure.
        const error = new APIError(503, 'storage_unavailable', 'Terrain storage is temporarily unavailable.');
        error.ambiguous = false; error.providerWide = false;
        throw error;
      }
      return { datasetVersion: raster.datasetVersion, body: { format: 'pttr-v1', sha256: packed.sha256,
        storagePath, bytes: packed.bytes.length, width: tile.width, height: tile.height, bounds,
        resolutionMeters: RESOLUTION_METERS, sources: raster.sources,
        captureDateMin: raster.captureDateMin, captureDateMax: raster.captureDateMax } };
    } };
}

async function route(request) {
  const url = new URL(request.url);
  // Anchor the complete prefix: never find an arbitrary /api/v1 substring.
  const match = /^(?:\/functions\/v1)?\/golf-data(\/api\/v1\/.*)$/.exec(url.pathname);
  if (!match) throw new APIError(404, 'not_found', 'Route not found.');
  const path = match[1];
  const search = /^\/api\/v1\/golf\/(clubs|courses)$/.exec(path);
  const catalogSearch = path === '/api/v1/catalog/clubs';
  const detail = /^\/api\/v1\/golf\/(courses|coordinates)\/([A-Za-z0-9_-]{1,100})$/.exec(path);
  const bundle = /^\/api\/v1\/golf\/courses\/([A-Za-z0-9_-]{1,100})\/bundle$/.exec(path);
  const terrain = /^\/api\/v1\/golf\/terrain\/([a-f0-9]{64})$/.exec(path);
  if (!search && !catalogSearch && !detail && !bundle && !terrain) throw new APIError(404, 'not_found', 'Route not found.');
  if (request.method !== 'GET') throw new APIError(405, 'method_not_allowed', 'Method not allowed.');
  if (catalogSearch) {
    const raw = parameters(url.searchParams, ['q', 'country', 'state', 'countries', 'page', 'pageSize']);
    const query = {};
    let hasQuery = false;
    let hasCountry = false;
    let hasState = false;
    for (const [key, value] of Object.entries(raw)) {
      const max = { q: 200, country: 120, state: 120, countries: 6000, page: 4, pageSize: 2 }[key];
      if ([...value].length > max || key === 'page' && !/^[1-9][0-9]{0,3}$/.test(value)
          || key === 'pageSize' && !/^(?:[1-9]|[1-4][0-9]|50)$/.test(value)) invalid();
      const normalized = value.trim().normalize('NFC');
      if (normalized) {
        query[key] = normalized;
        if (key === 'q') hasQuery = true;
        if (key === 'country') hasCountry = true;
        if (key === 'state') hasState = true;
      }
    }
    const countries = query.countries ? query.countries.split('|').map(country => country.trim().normalize('NFC')) : [];
    if (countries.length > 100 || countries.some(country => !country || [...country].length > 120)
        || new Set(countries.map(country => country.toLocaleLowerCase('en-US'))).size !== countries.length
        || query.country && countries.length) invalid();
    if (!hasQuery && !hasCountry && !hasState && countries.length === 0) {
      throw new APIError(400, 'search_required', 'Supply a club name, country or state.');
    }
    query.page ??= '1';
    query.pageSize ??= '50';
    return { kind: 'catalog-search', query, countries };
  }
  if (search) {
    const raw = parameters(url.searchParams, ['country', 'state', 'name', 'page', 'timestampUpdated']);
    const query = {};
    for (const [key, value] of Object.entries(raw)) {
      if ([...value].length > ({ country: 120, state: 120, name: 200, page: 4, timestampUpdated: 100 })[key]
          || key === 'page' && !/^[1-9][0-9]{0,3}$/.test(value)) invalid();
      const normalized = value.trim().normalize('NFC');
      if (normalized) query[key] = normalized;
    }
    if (!query.country && !query.state && !query.name) {
      throw new APIError(400, 'search_required', 'Supply country, state or name.');
    }
    query.page ??= '1';
    const kind = search[1];
    const canonical = Object.keys(query).sort().map(k => [k, query[k]]);
    return { provider: 'golf', key: `golf:v1:${kind}:${await hash(JSON.stringify(canonical))}`,
      maxAge: query.timestampUpdated ? 86400 : null, metadata: {},
      acquire: providers => providers.golf(`/${kind}`, query, kind) };
  }
  parameters(url.searchParams, []);
  if (bundle) return { kind: 'bundle', id: bundle[1] };
  if (terrain) return { kind: 'terrain', id: terrain[1] };
  return golfDetail(detail[1], detail[2]);
}

function response(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), { status, headers: {
    'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff', ...headers
  } });
}

function send({ body, cache, fetchedAt, datasetVersion: version }) {
  const headers = { 'X-Cache': cache };
  if (typeof fetchedAt === 'string' && /^\d{4}-\d\d-\d\dT[0-9:.]+Z$/.test(fetchedAt)
      && Number.isFinite(Date.parse(fetchedAt))) headers['X-Fetched-At'] = fetchedAt;
  if (typeof version === 'string' && /^[\x20-\x7e]{1,200}$/.test(version)) headers['X-Dataset-Version'] = version;
  return response(body, 200, headers);
}

function claimError(claim, missingConfig) {
  const retry = Number.isInteger(claim.retryAfter) ? Math.max(1, Math.min(86400, claim.retryAfter)) : undefined;
  const statuses = {
    FORBIDDEN: [403, 'forbidden', 'Account is not allowed to access data.'],
    RATE_LIMIT: [429, 'rate_limit', 'Request allowance exceeded.', retry ?? 2],
    BUDGET: [503, 'daily_budget_exceeded', 'Provider daily request budget exhausted.'],
    DISABLED: [503, 'provider_disabled', 'Fetching uncached provider data is disabled.'],
    COOLDOWN: [503, 'provider_cooldown', 'Provider requests are temporarily paused.', retry],
    PENDING: [503, 'request_pending', 'A request for this data is already in progress.', 2],
    UNKNOWN: [503, 'ambiguous_attempt', 'Previous provider attempt is ambiguous; operator resolution is required.'],
    CACHE_MISS: missingConfig
      ? [503, 'provider_not_configured', 'Provider is not configured.']
      : [404, 'cache_miss', 'Requested data has not been cached.']
  };
  return own(statuses, claim.status) ? new APIError(...statuses[claim.status]) : unavailable();
}

export function createHandler({ authenticate, rpc, providers, storage }) {
  // Every request, including hits, goes through the SQL account/banned gate.
  async function load(userID, operation, cacheOnlyRequested) {
    const { key, provider, metadata } = operation;
    const configured = providers.configured?.[provider] === true;
    const cacheOnly = cacheOnlyRequested || !configured;
    const claim = await rpc('pintheory_data_claim', { p_user_id: userID, p_key: key,
      p_provider: provider, p_cache_only: cacheOnly, p_max_age_seconds: operation.maxAge });
    if (!object(claim)) throw unavailable();
    if (claim.status === 'HIT') {
      if (!object(claim.body)) throw unavailable();
      if (metadata.courseID && await rpc('pintheory_data_tag', { p_key: key, p_course_id: metadata.courseID }) !== true) {
        throw unavailable();
      }
      return { body: claim.body, cache: 'HIT', fetchedAt: claim.fetchedAt, datasetVersion: claim.datasetVersion };
    }
    if (claim.status !== 'CLAIMED') throw claimError(claim, !configured);
    if (typeof claim.token !== 'string' || !UUID.test(claim.token)) throw unavailable();
    // Defense in depth if the DB unexpectedly returns CLAIMED for cache-only.
    if (cacheOnly) {
      try { await rpc('pintheory_data_fail', { p_key: key, p_token: claim.token,
        p_provider_wide: false, p_retry_after: 300 }); } catch { /* No dispatch or retry. */ }
      throw unavailable();
    }
    let result;
    try { result = await operation.acquire(providers); }
    catch (error) {
      if (!(error instanceof APIError) || error.ambiguous === true) {
        // Keep dispatched and all reservations: only an operator may allow another paid send.
        throw new APIError(503, 'ambiguous_attempt', 'Provider attempt is ambiguous; operator resolution is required.');
      }
      try {
        await rpc('pintheory_data_fail', { p_key: key, p_token: claim.token,
          p_provider_wide: error.providerWide !== false,
          p_retry_after: Math.max(300, Math.min(86400, Number.isInteger(error.retryAfter) ? error.retryAfter : 300)) });
      } catch { throw unavailable(); }
      throw error;
    }
    // Never fail/reclaim/replay after a finish failure: commit outcome may be unknown.
    const finished = await rpc('pintheory_data_finish', { p_key: key, p_token: claim.token,
      p_body: result.body, p_dataset_version: result.datasetVersion ?? null, p_metadata: metadata });
    if (finished !== true) throw new APIError(503, 'cache_write_rejected', 'Provider result could not be committed.');
    return { body: result.body, cache: 'MISS', fetchedAt: new Date().toISOString(), datasetVersion: result.datasetVersion };
  }

  // Terrain never blocks the course: each tile reports ready, pending or unavailable.
  async function courseTerrain(userID, courseID, coordinates) {
    const bounds = courseBounds(coordinates?.coordinates);
    const tiles = bounds && await terrainTiles(bounds);
    if (!tiles) return { status: 'unavailable', code: bounds ? 'course_too_large' : 'invalid_geometry', tiles: [] };
    const results = [];
    for (const tile of tiles) {
      try {
        const loaded = await load(userID, rasterTile(tile, courseID, storage), false);
        const b = loaded.body;
        if (b.format !== 'pttr-v1' || !/^[a-f0-9]{64}$/.test(b.sha256)) throw unavailable();
        results.push({ status: 'ready', id: tile.id, sha256: b.sha256, bytes: b.bytes, width: b.width,
          height: b.height, bounds: b.bounds, resolutionMeters: b.resolutionMeters, sources: b.sources ?? [],
          captureDateMin: b.captureDateMin ?? null, captureDateMax: b.captureDateMax ?? null,
          datasetVersion: loaded.datasetVersion ?? null, fetchedAt: loaded.fetchedAt ?? null });
      } catch (error) {
        const code = error instanceof APIError ? error.code : 'service_unavailable';
        results.push({ status: code === 'request_pending' ? 'pending' : 'unavailable', id: tile.id, code });
      }
    }
    const status = results.every(t => t.status === 'ready') ? 'ready'
      : results.some(t => t.status === 'pending') ? 'pending' : 'unavailable';
    return { status, tiles: results };
  }

  return async function handle(request) {
    try {
      // Native iOS has no Origin. No browser origin, including "null", is accepted.
      if (request.headers.has('origin') || request.method === 'OPTIONS') {
        throw new APIError(403, 'origin_forbidden', 'Browser requests are not allowed.');
      }
      const authorization = request.headers.get('authorization') ?? '';
      const bearer = /^Bearer ([^\s,]{1,8192})$/i.exec(authorization);
      if (!bearer) throw new APIError(401, 'unauthorized', 'Valid user bearer token required.');
      const user = await authenticate(bearer[1]);
      if (!user || typeof user.id !== 'string' || !UUID.test(user.id)) {
        throw new APIError(401, 'unauthorized', 'Valid user bearer token required.');
      }
      const operation = await route(request);
      const cacheOnly = request.headers.get('x-cache-only') === 'true';
      if (operation.kind === 'catalog-search') {
        const page = await rpc('pintheory_catalog_search', {
          p_user_id: user.id,
          p_query: operation.query.q ?? '',
          p_country: operation.query.country ?? '',
          p_state: operation.query.state ?? '',
          p_countries: operation.countries,
          p_page: Number(operation.query.page),
          p_page_size: Number(operation.query.pageSize)
        });
        if (!object(page) || !Array.isArray(page.clubs)
            || !Number.isSafeInteger(page.numClubs) || !Number.isSafeInteger(page.numAllClubs)
            || typeof page.datasetVersion !== 'string' || typeof page.hasMore !== 'boolean') throw unavailable();
        return response(page, 200, { 'X-Dataset-Version': page.datasetVersion });
      }
      if (operation.kind === 'bundle') {
        const detail = await load(user.id, golfDetail('courses', operation.id), cacheOnly);
        const coordinates = await load(user.id, golfDetail('coordinates', operation.id), cacheOnly);
        const terrain = await courseTerrain(user.id, operation.id, coordinates.body);
        return response({ detail: detail.body, coordinates: coordinates.body, terrain });
      }
      if (operation.kind === 'terrain') {
        const tile = await load(user.id, { provider: 'gpxz', key: `gpxz:raster:v1:${operation.id}`, maxAge: null,
          metadata: {}, acquire: () => { throw unavailable(); } }, true);
        const { storagePath, sha256 } = tile.body;
        if (typeof storagePath !== 'string' || storagePath !== `${sha256}.pttr`) throw unavailable();
        const bytes = await storage.download(storagePath, TERRAIN_DOWNLOAD_LIMIT);
        if (await sha256Hex(bytes) !== sha256) throw unavailable();
        return new Response(bytes, { status: 200, headers: { 'Content-Type': 'application/octet-stream',
          'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'X-Content-SHA256': sha256 } });
      }
      return send(await load(user.id, operation, cacheOnly));
    } catch (error) {
      const known = error instanceof APIError;
      return response({ error: { code: known ? error.code : 'service_unavailable',
        message: known ? error.message : 'Data service is temporarily unavailable.' } },
      known ? error.statusCode : 503, known && error.retryAfter ? { 'Retry-After': String(error.retryAfter) } : {});
    }
  };
}
