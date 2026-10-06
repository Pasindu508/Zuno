import type { SupabaseClient } from "@supabase/supabase-js";
import { optionalEnv } from "../_shared/env.ts";
import { createLogger } from "../_shared/log.ts";
import { callRpc, createAdminClient } from "../_shared/supabase.ts";
import { type ApplyResult, createNotifyHandler } from "./handler.ts";

const log = createLogger("payhere-notify");
let admin: SupabaseClient | null = null;

Deno.serve(createNotifyHandler({
  merchantId: optionalEnv("PAYHERE_MERCHANT_ID"),
  merchantSecret: optionalEnv("PAYHERE_MERCHANT_SECRET"),
  log,
  applyNotification: (args) => {
    admin ??= createAdminClient();
    return callRpc<ApplyResult>(admin, "apply_payhere_notification", {
      p_order_id: args.orderId,
      p_payment_id: args.paymentId,
      p_status_code: args.statusCode,
      p_amount_minor: args.amountMinor,
      p_currency: args.currency,
      p_method: args.method,
      p_notification: args.notification,
    });
  },
}));
