import { emitKeypressEvents } from 'node:readline';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const fail = message => { throw new Error(message); };

// Never print response bodies, tokens, passwords or provider credit balances.
async function jsonRequest(fetchImpl, url, options) {
  let response;
  try {
    response = await fetchImpl(url, { ...options, redirect: 'error', signal: AbortSignal.timeout(90000) });
  } catch {
    fail('Request outcome is uncertain. Stopped without retry; inspect the hosted cache before another run.');
  }
  if (!response.ok) fail(`HTTP ${response.status}. Stopped without retry; no further page requested.`);
  let body;
  try { body = await response.json(); } catch { fail('Invalid response. Stopped without retry.'); }
  return { response, body };
}

/** Only pages 1–3 of the exact country-only Sweden query; no details/coordinates. */
export async function cacheSwedenClubs({ projectRef, publicKey, accessToken, fetchImpl = fetch, log = console.log }) {
  if (!/^[a-z0-9]{20}$/.test(projectRef)) fail('An explicit hosted project reference is required.');
  if (!publicKey || !accessToken || publicKey.startsWith('sb_secret_')) fail('Public key and signed-in user token required.');
  const root = `https://${projectRef}.supabase.co`;
  const headers = { apikey: publicKey, Authorization: `Bearer ${accessToken}`, Accept: 'application/json' };
  const ids = new Set();
  let total;
  let fetched = 0;
  for (let page = 1; page <= 3; page++) {
    const url = `${root}/functions/v1/golf-data/api/v1/golf/clubs?country=Sweden&page=${page}`;
    // The deployed claim/finish flow reuses cached pages, enforces budgets and
    // ambiguity fences, and persists a provider result before returning success.
    const { response, body } = await jsonRequest(fetchImpl, url, { headers });
    const cache = response.headers.get('x-cache');
    if (!['HIT', 'MISS'].includes(cache)) fail('Cache persistence was not confirmed. Stopped.');
    if (cache === 'MISS') fetched++;
    const reportedTotal = body?.numAllClubs;
    const count = typeof reportedTotal === 'number' || typeof reportedTotal === 'string' && /^\d+$/.test(reportedTotal)
      ? Number(reportedTotal) : NaN;
    if (!Array.isArray(body?.clubs) || body.clubs.length > 200 || !Number.isSafeInteger(count) || count < 0
        || total !== undefined && total !== count) fail('Missing/inconsistent directory totals. Stopped; completeness is not established.');
    total = count;
    const expectedCount = Math.min(200, Math.max(0, total - (page - 1) * 200));
    if (body.clubs.length !== expectedCount) fail('Unexpected page size. Stopped; completeness is not established.');
    for (const club of body.clubs) {
      if (!club || !['string', 'number'].includes(typeof club.clubID) || !String(club.clubID)
          || ids.has(String(club.clubID))) fail('Missing/duplicate club identity. Stopped; completeness is not established.');
      ids.add(String(club.clubID));
    }
    log(`Sweden page ${page}: ${body.clubs.length} clubs; cache ${cache}; ${ids.size}/${total} unique clubs.`);
    if (ids.size === total) {
      log(`Complete Sweden directory cached: ${total} clubs; ${fetched} newly fetched pages. No details or GPS requested.`);
      return { complete: true, total, fetched, pages: page };
    }
  }
  log(`Stopped at the authorized three-page limit: ${ids.size}/${total} clubs cached. Directory is NOT complete.`);
  return { complete: false, total, fetched, pages: 3 };
}

export function createPrompter(input = process.stdin, output = process.stdout) {
  emitKeypressEvents(input);
  const previousRaw = Boolean(input.isRaw);
  let cancel;
  function restore() {
    input.setRawMode(previousRaw);
    input.pause();
  }
  return {
    prompt(label, secret = false) {
      return new Promise((resolve, reject) => {
        let value = '';
        const finish = error => {
          input.removeListener('keypress', onKey);
          input.removeListener('end', onEnd);
          cancel = undefined;
          restore();
          output.write(secret && !error ? '\nInput received.\n' : '\n');
          if (error) reject(error); else resolve(value.trim());
        };
        const onEnd = () => finish(new Error('Input closed. No further requests sent.'));
        const onKey = (text, key = {}) => {
          if (key.ctrl && ['c', 'd'].includes(key.name)) return finish(new Error('Cancelled.'));
          if (['return', 'enter'].includes(key.name)) return finish();
          if (key.name === 'backspace') {
            value = Array.from(value).slice(0, -1).join('');
            return;
          }
          // Do not echo input, including authentication method. Ignore terminal
          // controls/escape sequences; printable pasted Unicode is preserved.
          if (text && !key.ctrl && !key.meta && !/[\x00-\x1f\x7f]/.test(text)) value += text;
        };
        cancel = onEnd;
        input.on('keypress', onKey);
        input.once('end', onEnd);
        input.setRawMode(true);
        output.write(label);
        input.resume();
      });
    },
    close() { if (cancel) cancel(); else restore(); }
  };
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length !== 2 || args[0] !== '--project-ref' || !/^[a-z0-9]{20}$/.test(args[1])) {
    fail('Usage: node scripts/cache-sweden-clubs.mjs --project-ref <intended-project-ref>');
  }
  if (!process.stdin.isTTY) fail('Run interactively in a terminal. Do not pass credentials as command arguments.');
  const projectRef = args[1];
  console.log(`Target: https://${projectRef}.supabase.co. Maximum THREE Sweden club search requests, no retries.`);
  console.log('Enter credentials directly here, never in chat. Provider/service-role keys are not accepted.');
  console.log('Paste each hidden value, then press Return. No network request occurs until account credentials are entered.');
  const prompter = createPrompter();
  const prompt = prompter.prompt;
  try {
  const publicKey = await prompt('Supabase publishable/anon key (hidden): ', true);
  if (!publicKey || publicKey.startsWith('sb_secret_')) fail('A public project key is required.');
  const method = await prompt('Sign in with email/password or existing user token? [email/token]: ');
  let accessToken;
  if (method === 'token') {
    accessToken = await prompt('Signed-in app user access token (hidden): ', true);
  } else if (method === 'email') {
    const email = await prompt('App account email (hidden): ', true);
    const password = await prompt('App account password (hidden): ', true);
    const { body } = await jsonRequest(fetch, `https://${projectRef}.supabase.co/auth/v1/token?grant_type=password`, {
      method: 'POST', headers: { apikey: publicKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password })
    });
    accessToken = body?.access_token;
    if (typeof accessToken !== 'string' || body?.user?.is_anonymous !== false) fail('Nonanonymous user sign-in required.');
  } else fail('Choose email or token. No search requests sent.');
  prompter.close();
  const result = await cacheSwedenClubs({ projectRef, publicKey, accessToken });
  if (!result.complete) process.exitCode = 2;
  } finally { prompter.close(); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}