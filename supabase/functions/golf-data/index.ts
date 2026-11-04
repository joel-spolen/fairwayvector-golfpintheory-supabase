import { createHandler } from './handler.js';
import { Providers } from '../_shared/providers.js';
import { createSupabase } from '../_shared/supabase.js';

const { authenticate, rpc, storage } = createSupabase({
  url: Deno.env.get('SUPABASE_URL'),
  anonKey: Deno.env.get('SUPABASE_ANON_KEY'),
  serviceKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
});
const providers = new Providers({ providers: {
  golf: { key: Deno.env.get('GOLF_API_KEY') },
  gpxz: { key: Deno.env.get('GPXZ_API_KEY') },
  lantmateriet: { username: Deno.env.get('LANTMATERIET_USERNAME'), password: Deno.env.get('LANTMATERIET_PASSWORD') }
} });

// Supabase's runtime keeps the function alive for promises passed to waitUntil after responding.
const runtime = (globalThis as { EdgeRuntime?: { waitUntil(promise: Promise<unknown>): void } }).EdgeRuntime;
const background = (promise: Promise<unknown>) => { runtime?.waitUntil(promise); };

Deno.serve(createHandler({ authenticate, rpc, providers, storage, background }));