// payhere-checkout: validates the request, creates a pending order priced by
// the database (create_payment_order, service role) and returns the signed
// PayHere checkout form. The client never supplies prices or totals (except
// the wallet top-up amount, which is bounded by platform settings).
import {
  HttpError,
  isUuid,
  json,
  readJsonObject,
  requireMethod,
  requireUuid,
  withErrorHandling,
} from "../_shared/http.ts";
import type { Logger } from "../_shared/log.ts";
import { checkoutActionUrl, checkoutHash, formatAmount } from "../_shared/payhere.ts";
import { RATE_LIMITS, type RateLimitRule } from "../_shared/ratelimit.ts";

export type OrderKind = "ticket" | "wallet_topup" | "event_creation_fee";

export interface OrderRequest {
  kind: OrderKind;
  eventId: string | null;
  items: { tier_id: string; quantity: number }[] | null;
  amountMinor: number | null;
  answers: unknown[] | null;
  idempotencyKey: string;
}

export interface OrderSummary {
  order_id: string;
  kind: OrderKind;
  status: string;
  expires_at: string;
  summary: {
    lines: { label: string; quantity: number; unit_price_minor: number; amount_minor: number }[];
    subtotal_minor: number;
    commission_minor: number;
    total_minor: number;
    currency: string;
  };
  item_description: string;
  customer: { first_name: string; last_name: string; email: string | null; city: string };
}

export interface CheckoutConfig {
  merchantId: string;
  merchantSecret: string;
  mode: string | undefined;
  returnUrl: string;
  notifyUrl: string;
  fallbackEmail: string | undefined;
}

export interface CheckoutDeps {
  authenticate(req: Request): Promise<string>;
  rateLimit(key: string, rule: RateLimitRule): Promise<void>;
  createOrder(userId: string, order: OrderRequest): Promise<OrderSummary>;
  config(): CheckoutConfig; // throws HttpError 503 when PayHere is not configured
  log: Logger;
}

const PHONE_RE = /^\+?[0-9]{9,15}$/;

export function parseCheckoutBody(
  body: Record<string, unknown>,
  headerKey: string | null,
): OrderRequest & { phone: string } {
  const kind = body.kind;
  if (kind !== "ticket" && kind !== "wallet_topup" && kind !== "event_creation_fee") {
    throw new HttpError(400, "invalid_kind", "kind must be ticket, wallet_topup or event_creation_fee.");
  }
  const idempotencyKey = typeof body.idempotency_key === "string" ? body.idempotency_key : headerKey;
  if (typeof idempotencyKey !== "string" || idempotencyKey.length < 8 || idempotencyKey.length > 200) {
    throw new HttpError(400, "invalid_idempotency_key", "idempotency_key must be 8-200 characters.");
  }
  const phone = typeof body.phone === "string" ? body.phone.replace(/[\s-]/g, "") : "";
  if (!PHONE_RE.test(phone)) throw new HttpError(400, "invalid_phone", "phone must be a valid phone number.");

  if (kind === "ticket") {
    const eventId = requireUuid(body.event_id, "event_id");
    if (!Array.isArray(body.items) || body.items.length < 1 || body.items.length > 10) {
      throw new HttpError(400, "invalid_items", "items must contain 1-10 lines.");
    }
    const items = body.items.map((item) => {
      if (item === null || typeof item !== "object") throw new HttpError(400, "invalid_items", "Invalid item.");
      const { tier_id, quantity } = item as Record<string, unknown>;
      if (!isUuid(tier_id) || !Number.isInteger(quantity) || (quantity as number) < 1 || (quantity as number) > 50) {
        throw new HttpError(400, "invalid_items", "Each item needs tier_id and quantity 1-50.");
      }
      return { tier_id: tier_id.toLowerCase(), quantity: quantity as number };
    });
    if (body.answers !== undefined && body.answers !== null && !Array.isArray(body.answers)) {
      throw new HttpError(400, "answers_invalid", "answers must be an array.");
    }
    const answers = Array.isArray(body.answers) ? body.answers : [];
    return { kind, eventId, items, amountMinor: null, answers, idempotencyKey, phone };
  }
  if (kind === "wallet_topup") {
    if (!Number.isSafeInteger(body.amount_minor) || (body.amount_minor as number) <= 0) {
      throw new HttpError(400, "invalid_amount", "amount_minor must be a positive integer.");
    }
    return {
      kind,
      eventId: null,
      items: null,
      amountMinor: body.amount_minor as number,
      answers: null,
      idempotencyKey,
      phone,
    };
  }
  const eventId = requireUuid(body.event_id, "event_id");
  return { kind, eventId, items: null, amountMinor: null, answers: null, idempotencyKey, phone };
}

export async function buildCheckoutFields(order: OrderSummary, phone: string, config: CheckoutConfig) {
  const email = order.customer.email ?? config.fallbackEmail;
  if (!email) throw new HttpError(400, "email_required", "Add an e-mail address to your account to pay with PayHere.");
  const separator = config.returnUrl.includes("?") ? "&" : "?";
  const returnUrl = `${config.returnUrl}${separator}order_id=${order.order_id}`;
  return {
    merchant_id: config.merchantId,
    return_url: returnUrl,
    cancel_url: `${returnUrl}&cancelled=1`,
    notify_url: config.notifyUrl,
    order_id: order.order_id,
    items: order.item_description,
    currency: order.summary.currency,
    amount: formatAmount(order.summary.total_minor),
    first_name: order.customer.first_name,
    last_name: order.customer.last_name,
    email,
    phone,
    address: "N/A",
    city: order.customer.city,
    country: "Sri Lanka",
    hash: await checkoutHash(
      config.merchantId,
      order.order_id,
      order.summary.total_minor,
      order.summary.currency,
      config.merchantSecret,
    ),
  };
}

export function createCheckoutHandler(deps: CheckoutDeps): (req: Request) => Promise<Response> {
  return withErrorHandling(deps.log, async (req) => {
    requireMethod(req, "POST");
    const userId = await deps.authenticate(req);
    await deps.rateLimit(`checkout:${userId}`, RATE_LIMITS.checkout);
    const config = deps.config();
    const request = parseCheckoutBody(await readJsonObject(req), req.headers.get("idempotency-key"));

    const order = await deps.createOrder(userId, request);
    if (order.status !== "pending") {
      throw new HttpError(
        409,
        "order_not_pending",
        `Order ${order.order_id} is ${order.status}; start a new checkout.`,
      );
    }
    const fields = await buildCheckoutFields(order, request.phone, config);
    deps.log.info("checkout created", { user_id: userId, order_id: order.order_id, kind: order.kind });
    return json({
      order_id: order.order_id,
      status: order.status,
      expires_at: order.expires_at,
      summary: order.summary,
      checkout: { action_url: checkoutActionUrl(config.mode), method: "POST", fields },
    });
  });
}
