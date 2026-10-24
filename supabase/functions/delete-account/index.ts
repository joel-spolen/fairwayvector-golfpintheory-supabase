import { createClient } from "npm:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const allowedOrigin = Deno.env.get("CORS_ALLOWED_ORIGIN");

const jsonHeaders = { "Content-Type": "application/json; charset=utf-8" };

function response(status: number, body: Record<string, string>, headers = new Headers()) {
  for (const [key, value] of Object.entries(jsonHeaders)) headers.set(key, value);
  return new Response(JSON.stringify(body), { status, headers });
}

Deno.serve(async (request: Request) => {
  const headers = new Headers({ Vary: "Origin" });
  try {
    const origin = request.headers.get("origin");

    // Native app requests normally omit Origin. Browser access is opt-in to one
    // exact app origin; this is not an authentication control.
    if (origin !== null) {
      if (!allowedOrigin || origin !== allowedOrigin) {
        return response(403, { error: "origin_not_allowed" }, headers);
      }
      headers.set("Access-Control-Allow-Origin", allowedOrigin);
      headers.set("Access-Control-Allow-Headers", "authorization, apikey, content-type, x-client-info");
      headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    }
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers });
    }
    if (request.method !== "POST") {
      headers.set("Allow", "POST, OPTIONS");
      return response(405, { error: "method_not_allowed" }, headers);
    }
    if (!supabaseUrl || !anonKey || !serviceRoleKey) {
      return response(503, { error: "deletion_service_unavailable" }, headers);
    }

    const authorization = request.headers.get("authorization") ?? "";
    const bearer = authorization.match(/^Bearer\s+([^\s]+)$/i)?.[1];
    if (!bearer) return response(401, { error: "authentication_required" }, headers);

    const userClient = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      global: { headers: { Authorization: `Bearer ${bearer}` } },
    });
    const { data: userResult, error: userError } = await userClient.auth.getUser(bearer);
    if (userError || !userResult.user) {
      return response(401, { error: "authentication_required" }, headers);
    }

    // This authenticated RPC locks the account against concurrent sync and
    // enforces the <=10-minute JWT iat requirement on the first transition only.
    const { error: beginError } = await userClient.rpc("pintheory_begin_account_deletion");
    if (beginError) {
      if (beginError.code === "42501") {
        return response(403, { error: "recent_authentication_required_or_deletion_blocked" }, headers);
      }
      return response(503, { error: "deletion_pending" }, headers);
    }

    const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });
    const { error: purgeError } = await serviceClient.rpc("pintheory_purge_account", {
      p_user_id: userResult.user.id,
    });
    if (purgeError) {
      return response(503, { error: "deletion_pending" }, headers);
    }

    // Auth identity removal is last. If it fails, the account remains blocked
    // and a still-valid user session can safely retry the idempotent workflow.
    const { error: deleteError } = await serviceClient.auth.admin.deleteUser(userResult.user.id);
    if (deleteError) {
      return response(503, { error: "deletion_pending" }, headers);
    }

    return response(200, { status: "deleted" }, headers);
  } catch {
    // Network/SDK failures remain retryable; do not expose provider details.
    return response(503, { error: "deletion_pending" }, headers);
  }
});