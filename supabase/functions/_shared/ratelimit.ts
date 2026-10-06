// Fixed-window rate limiting backed by public.rate_limit_hit (service role only).
import type { SupabaseClient } from "@supabase/supabase-js";
import { HttpError } from "./http.ts";
import { callRpc } from "./supabase.ts";

export interface RateLimitRule {
  limit: number;
  windowSeconds: number;
}

export const RATE_LIMITS = {
  nicDigest: { limit: 5, windowSeconds: 3600 },
  checkout: { limit: 20, windowSeconds: 600 },
  aiCopilot: { limit: 10, windowSeconds: 3600 },
  deleteAccount: { limit: 3, windowSeconds: 3600 },
  organizerExport: { limit: 20, windowSeconds: 3600 },
} satisfies Record<string, RateLimitRule>;

export async function enforceRateLimit(admin: SupabaseClient, key: string, rule: RateLimitRule): Promise<void> {
  const allowed = await callRpc<boolean>(admin, "rate_limit_hit", {
    p_key: key,
    p_limit: rule.limit,
    p_window_seconds: rule.windowSeconds,
  });
  if (!allowed) throw new HttpError(429, "rate_limited", "Too many requests. Please try again later.");
}
