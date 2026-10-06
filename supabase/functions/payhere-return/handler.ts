// payhere-return: PayHere browser redirect target (return_url / cancel_url).
// Informational only - never treated as proof of payment. Redirects into the
// app, which then reads the order status (Realtime / orders table).
import { isUuid } from "../_shared/http.ts";
import type { Logger } from "../_shared/log.ts";

export function returnLocation(url: URL): string {
  // PayHere may append its own order_id; take the first valid UUID.
  const orderId = url.searchParams.getAll("order_id").find((value) => isUuid(value));
  return orderId ? `zuno://payments/return?order_id=${orderId.toLowerCase()}` : "zuno://payments/return";
}

export function createReturnHandler(log: Logger): (req: Request) => Response {
  return (req: Request) => {
    if (req.method !== "GET" && req.method !== "POST" && req.method !== "HEAD") {
      return new Response("method not allowed", { status: 405 });
    }
    const location = returnLocation(new URL(req.url));
    log.info("redirecting to app", { has_order_id: location.includes("order_id=") });
    return new Response(null, { status: 302, headers: { Location: location, "Cache-Control": "no-store" } });
  };
}
