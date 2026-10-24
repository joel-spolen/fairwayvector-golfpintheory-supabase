import { APIError } from '../_shared/errors.js';
import { profileRequest } from '../_shared/geometry.js';
import { readText, withDeadline } from '../_shared/web.js';

const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const identifier = /^[A-Za-z0-9_-]{1,100}$/;
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const invalid = () => { throw new APIError(400, 'invalid_request', 'Request rejected.'); };
const unavailable = () => new APIError(503, 'service_unavailable', 'Data service is temporarily unavailable.');
const own = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key);

async function hash(value) {
  const bytes = await globalThis.crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return Array.from(new Uint8Array(bytes), b => b.toString(16).padStart(2, '0')).join('');
}

function parameters(search, allowed) {
  const values = Object.create(null);
  for (const [key, value] of search) {
    if (!allowed.includes(key) || own(values, key)) invalid();
    values[key] = value;
  }
  return values;
}

async function elevationBody(request) {
  if (Number(request.headers.get('content-length')) > 300000) {
    throw new APIError(413, 'body_too_large', 'Request body is too large.');
  }
  const type = request.headers.get('content-type')?.split(';')[0].trim().toLowerCase();
  if (!['application/json', 'application/x-www-form-urlencoded'].includes(type)) {
    throw new APIError(415, 'unsupported_media_type', 'Use JSON or form encoding.');
  }
  let body;
  try {
    const text = await withDeadline(10000, signal => readText(request.body, 300000, signal));
    body = type === 'application/json' ? JSON.parse(text) : parameters(new URLSearchParams(text),
      ['path', 'latlons', 'samples', 'courseID', 'interpolation', 'bathymetry']);
  } catch (error) {
    if (error instanceof APIError) throw error;
    if (error instanceof RangeError) throw new APIError(413, 'body_too_large', 'Request body is too large.');
    invalid();
  }
  const fields = ['path', 'latlons', 'samples', 'courseID', 'interpolation', 'bathymetry'];
  if (!object(body) || Object.keys(body).some(key => !fields.includes(key))) invalid();
  if (own(body, 'path') && (!Array.isArray(body.path) || body.path.length < 2 || body.path.length > 5000
      || body.path.some(p => !object(p) || Object.keys(p).length !== 2
        || !own(p, 'lat') || !own(p, 'lon') || typeof p.lat !== 'number' || typeof p.lon !== 'number'))) invalid();
  if (own(body, 'latlons') && (typeof body.latlons !== 'string' || body.latlons.length > 250000)) invalid();
  if (own(body, 'samples') && !(Number.isInteger(body.samples)
      || typeof body.samples === 'string' && /^[0-9]{1,3}$/.test(body.samples))) invalid();
  if (own(body, 'courseID') && (typeof body.courseID !== 'string' || !identifier.test(body.courseID))) invalid();
  if (own(body, 'interpolation') && typeof body.interpolation !== 'string') invalid();
  if (own(body, 'bathymetry') && !['boolean', 'string'].includes(typeof body.bathymetry)) invalid();
  return body;
}

async function route(request) {
  const url = new URL(request.url);
  // Anchor the complete prefix: never find an arbitrary /api/v1 substring.
  const match = /^(?:\/functions\/v1)?\/golf-data(\/api\/v1\/.*)$/.exec(url.pathname);
  if (!match) throw new APIError(404, 'not_found', 'Route not found.');
  const path = match[1];
  const search = /^\/api\/v1\/golf\/(clubs|courses)$/.exec(path);
  const detail = /^\/api\/v1\/golf\/(courses|coordinates)\/([A-Za-z0-9_-]{1,100})$/.exec(path);
  const elevation = path === '/api/v1/elevation/sample';
  if (!search && !detail && !elevation) throw new APIError(404, 'not_found', 'Route not found.');
  if (request.method !== (elevation ? 'POST' : 'GET')) {
    throw new APIError(405, 'method_not_allowed', 'Method not allowed.');
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
  if (detail) {
    const [, collection, id] = detail;
    const kind = collection === 'courses' ? 'detail' : 'coordinates';
    return { provider: 'golf', key: `golf:v1:${kind}:${id}`, maxAge: null, metadata: {},
      acquire: providers => providers.golf(`/${collection}/${id}`, {}, kind, id) };
  }
  const body = await elevationBody(request);
  const profile = profileRequest(body);
  const key = `gpxz:sample:v1:${await hash(JSON.stringify({ path: profile.path, samples: profile.samples,
    interpolation: 'bilinear', bathymetry: false }))}`;
  return { provider: 'gpxz', key, maxAge: null,
    metadata: { profileLengthMeters: profile.length, ...(body.courseID ? { courseID: body.courseID } : {}) },
    acquire: providers => providers.elevation(profile) };
}

function response(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), { status, headers: {
    'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff', ...headers
  } });
}

function send(body, cache, fetchedAt, version) {
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

export function createHandler({ authenticate, rpc, providers }) {
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
      const { key, provider, metadata } = operation;
      const configured = providers.configured?.[provider] === true;
      const cacheOnly = request.headers.get('x-cache-only') === 'true' || !configured;
      // Every request, including hits, goes through the SQL account/banned gate.
      const claim = await rpc('pintheory_data_claim', { p_user_id: user.id, p_key: key,
        p_provider: provider, p_cache_only: cacheOnly, p_max_age_seconds: operation.maxAge });
      if (!object(claim)) throw unavailable();
      if (claim.status === 'HIT') {
        if (!object(claim.body)) throw unavailable();
        if (metadata.courseID && await rpc('pintheory_data_tag', { p_key: key, p_course_id: metadata.courseID }) !== true) {
          throw unavailable();
        }
        return send(claim.body, 'HIT', claim.fetchedAt, claim.datasetVersion);
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
      return send(result.body, 'MISS', new Date().toISOString(), result.datasetVersion);
    } catch (error) {
      const known = error instanceof APIError;
      return response({ error: { code: known ? error.code : 'service_unavailable',
        message: known ? error.message : 'Data service is temporarily unavailable.' } },
      known ? error.statusCode : 503, known && error.retryAfter ? { 'Retry-After': String(error.retryAfter) } : {});
    }
  };
}