// Supabase clients and request authentication for Edge Functions.
import { createClient, type SupabaseClient, type User } from "@supabase/supabase-js";
import { optionalEnv, requireEnv } from "./env.ts";
import { dbError, HttpError } from "./http.ts";
import { timingSafeEqual } from "./crypto.ts";

/**
 * Service-role client (bypasses RLS). Used only after the caller has been
 * authenticated and authorised; user-scoped RPCs receive p_user_id explicitly.
 */
export function createAdminClient(): SupabaseClient {
  const url = requireEnv("SUPABASE_URL");
  const serviceKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
  return createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { headers: { "x-client-info": "zuno-edge-functions" } },
  });
}

export function bearerToken(req: Request): string | null {
  const header = req.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  return match ? match[1].trim() : null;
}

/** Validates the caller's access token with the Auth server (auth.getUser). */
export async function authenticateUser(req: Request, admin: SupabaseClient): Promise<User> {
  const token = bearerToken(req);
  if (!token) throw new HttpError(401, "not_authenticated", "Missing bearer token.");
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data?.user) throw new HttpError(401, "not_authenticated", "Invalid or expired session.");
  return data.user;
}

/** True only when the bearer token is exactly the service-role key. */
export function isServiceRoleRequest(req: Request): boolean {
  const token = bearerToken(req);
  const serviceKey = optionalEnv("SUPABASE_SERVICE_ROLE_KEY");
  return Boolean(token && serviceKey && timingSafeEqual(token, serviceKey));
}

/** Calls a Postgres function and maps P0001 machine codes to HTTP errors. */
export async function callRpc<T>(admin: SupabaseClient, fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw dbError(error);
  return data as T;
}
