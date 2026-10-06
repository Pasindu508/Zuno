// nic-digest: verifies that a NIC is well-formed and unique across accounts
// without ever storing or logging it. Only HMAC-SHA-256(NIC_HMAC_KEY, canonical
// NIC) reaches the database (public.record_identity_digest, service role).
import { HttpError, json, readJsonObject, requireMethod, withErrorHandling } from "../_shared/http.ts";
import type { Logger } from "../_shared/log.ts";
import { canonicalizeNic, nicDigest } from "../_shared/nic.ts";
import { RATE_LIMITS, type RateLimitRule } from "../_shared/ratelimit.ts";

export interface NicDigestDeps {
  authenticate(req: Request): Promise<string>; // returns the user id
  rateLimit(key: string, rule: RateLimitRule): Promise<void>;
  hmacKey(): { key: Uint8Array; version: number }; // throws HttpError 503 when not configured
  recordDigest(
    userId: string,
    digest: string,
    keyVersion: number,
  ): Promise<{ status: "verified_unique" | "duplicate" }>;
  log: Logger;
}

export function createNicDigestHandler(deps: NicDigestDeps): (req: Request) => Promise<Response> {
  return withErrorHandling(deps.log, async (req) => {
    requireMethod(req, "POST");
    const userId = await deps.authenticate(req);
    // Rate limit before validation so format probing also counts.
    await deps.rateLimit(`nic:${userId}`, RATE_LIMITS.nicDigest);

    const body = await readJsonObject(req, 1024);
    const canonical = canonicalizeNic(body.nic);
    if (!canonical) {
      throw new HttpError(400, "invalid_format", "Enter a 12-digit NIC or a 9-digit NIC ending in V or X.");
    }
    const { key, version } = deps.hmacKey();
    const digest = await nicDigest(canonical, key);
    const result = await deps.recordDigest(userId, digest, version);
    // Log the outcome only - never the NIC or its digest.
    deps.log.info("identity check completed", { user_id: userId, status: result.status, key_version: version });
    return json({ status: result.status });
  });
}
