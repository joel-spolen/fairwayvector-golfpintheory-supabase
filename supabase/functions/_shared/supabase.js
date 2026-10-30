import { APIError } from './errors.js';
import { readText, cancelBody, withDeadline } from './web.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const RPCS = new Set(['pintheory_data_claim', 'pintheory_data_finish', 'pintheory_data_fail', 'pintheory_data_tag',
  'pintheory_catalog_search']);
const unavailable = () => new APIError(503, 'service_unavailable', 'Data service is temporarily unavailable.');
const unauthorized = () => new APIError(401, 'unauthorized', 'Valid user bearer token required.');

export function createSupabase({ url, anonKey, serviceKey }, { fetchImpl = globalThis.fetch, timeoutMs = 10000 } = {}) {
  // Only deployment-controlled environment is used to construct these endpoints.
  let root;
  try {
    const parsed = new URL(url);
    if (!['https:', 'http:'].includes(parsed.protocol) || parsed.username || parsed.password
        || parsed.pathname !== '/' || parsed.search || parsed.hash) throw unavailable();
    root = parsed.origin;
  } catch { /* Missing/malformed deployment config fails closed at request time. */ }

  async function json(endpoint, options, limit, auth = false) {
    try {
      return await withDeadline(timeoutMs, async signal => {
        const res = await fetchImpl(`${root}${endpoint}`, { ...options, redirect: 'error', signal });
        if (res.status !== 200 || res.redirected || signal.aborted) {
          cancelBody(res);
          if (auth && [401, 403].includes(res.status)) throw unauthorized();
          throw unavailable();
        }
        return JSON.parse(await readText(res.body, limit, signal));
      });
    } catch (error) {
      if (error instanceof APIError) throw error;
      throw unavailable();
    }
  }

  return {
    async authenticate(token) {
      if (!root || !anonKey) throw unavailable();
      if (!token || token === serviceKey || token === anonKey) throw unauthorized();
      const user = await json('/auth/v1/user', { method: 'GET',
        headers: { apikey: anonKey, Authorization: `Bearer ${token}`, Accept: 'application/json' } }, 256000, true);
      // Online GoTrue result only. No local JWT decode or public/admin fallback.
      if (!user || typeof user.id !== 'string' || !UUID.test(user.id) || user.is_anonymous !== false) throw unauthorized();
      return { id: user.id };
    },
    async rpc(name, args) {
      if (!root || !serviceKey || !RPCS.has(name)) throw unavailable();
      return await json(`/rest/v1/rpc/${name}`, { method: 'POST', headers: {
        apikey: serviceKey, ...(serviceKey.startsWith('sb_secret_') ? {} : { Authorization: `Bearer ${serviceKey}` }),
        'Content-Type': 'application/json', Accept: 'application/json'
      }, body: JSON.stringify(args) }, 5000000);
    }
  };
}