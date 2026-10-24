import { createHandler } from './handler.js';
import { Providers } from '../_shared/providers.js';
import { createSupabase } from '../_shared/supabase.js';

const { authenticate, rpc } = createSupabase({
  url: Deno.env.get('SUPABASE_URL'),
  anonKey: Deno.env.get('SUPABASE_ANON_KEY'),
  serviceKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
});
const providers = new Providers({ providers: {
  golf: { key: Deno.env.get('GOLF_API_KEY') },
  gpxz: { key: Deno.env.get('GPXZ_API_KEY') }
} });

Deno.serve(createHandler({ authenticate, rpc, providers }));