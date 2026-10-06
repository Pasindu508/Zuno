// Environment access. Secrets are configured with `supabase secrets set`
// (see supabase/functions/.env.example) and are never hard-coded.
import { HttpError } from "./http.ts";

export function optionalEnv(name: string): string | undefined {
  const value = Deno.env.get(name);
  return value === undefined || value.trim() === "" ? undefined : value;
}

/** Returns the variable or throws a 503 `<code>` HttpError when it is missing. */
export function requireEnv(name: string, code = "not_configured"): string {
  const value = optionalEnv(name);
  if (value === undefined) {
    throw new HttpError(503, code, `Server is missing configuration (${name}).`);
  }
  return value;
}
