import type { SupabaseClient } from "@supabase/supabase-js";
import { optionalEnv, requireEnv } from "../_shared/env.ts";
import { createLogger } from "../_shared/log.ts";
import { enforceRateLimit } from "../_shared/ratelimit.ts";
import { authenticateUser, callRpc, createAdminClient } from "../_shared/supabase.ts";
import { createCheckoutHandler, type OrderSummary } from "./handler.ts";

const log = createLogger("payhere-checkout");
let admin: SupabaseClient | null = null;
const client = () => (admin ??= createAdminClient());

Deno.serve(createCheckoutHandler({
  log,
  authenticate: async (req) => (await authenticateUser(req, client())).id,
  rateLimit: (key, rule) => enforceRateLimit(client(), key, rule),
  config: () => {
    const supabaseUrl = requireEnv("SUPABASE_URL").replace(/\/+$/, "");
    return {
      merchantId: requireEnv("PAYHERE_MERCHANT_ID", "payments_unavailable"),
      merchantSecret: requireEnv("PAYHERE_MERCHANT_SECRET", "payments_unavailable"),
      mode: optionalEnv("PAYHERE_MODE"),
      returnUrl: optionalEnv("PAYHERE_RETURN_URL") ?? `${supabaseUrl}/functions/v1/payhere-return`,
      notifyUrl: optionalEnv("PAYHERE_NOTIFY_URL") ?? `${supabaseUrl}/functions/v1/payhere-notify`,
      fallbackEmail: optionalEnv("PAYHERE_FALLBACK_EMAIL"),
    };
  },
  createOrder: (userId, order) =>
    callRpc<OrderSummary>(client(), "create_payment_order", {
      p_user_id: userId,
      p_kind: order.kind,
      p_event_id: order.eventId,
      p_items: order.items,
      p_amount_minor: order.amountMinor,
      p_idempotency_key: order.idempotencyKey,
      p_answers: order.answers,
    }),
}));
