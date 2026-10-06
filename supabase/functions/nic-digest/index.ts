import type { SupabaseClient } from "@supabase/supabase-js";
import { optionalEnv, requireEnv } from "../_shared/env.ts";
import { HttpError } from "../_shared/http.ts";
import { createLogger } from "../_shared/log.ts";
import { decodeHmacKey } from "../_shared/nic.ts";
import { enforceRateLimit } from "../_shared/ratelimit.ts";
import { authenticateUser, callRpc, createAdminClient } from "../_shared/supabase.ts";
import { createNicDigestHandler } from "./handler.ts";

const log = createLogger("nic-digest");
let admin: SupabaseClient | null = null;
const client = () => (admin ??= createAdminClient());

Deno.serve(createNicDigestHandler({
  log,
  authenticate: async (req) => (await authenticateUser(req, client())).id,
  rateLimit: (key, rule) => enforceRateLimit(client(), key, rule),
  hmacKey: () => {
    const secret = requireEnv("NIC_HMAC_KEY");
    const version = Number.parseInt(optionalEnv("NIC_HMAC_KEY_VERSION") ?? "1", 10);
    if (!Number.isInteger(version) || version < 1) {
      throw new HttpError(503, "not_configured", "NIC_HMAC_KEY_VERSION must be a positive integer.");
    }
    try {
      return { key: decodeHmacKey(secret), version };
    } catch {
      throw new HttpError(503, "not_configured", "NIC_HMAC_KEY is invalid.");
    }
  },
  recordDigest: (userId, digest, keyVersion) =>
    callRpc(client(), "record_identity_digest", { p_user_id: userId, p_digest: digest, p_key_version: keyVersion }),
}));
