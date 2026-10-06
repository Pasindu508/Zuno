import { assertEquals, assertThrows } from "@std/assert";
import { HttpError } from "../_shared/http.ts";
import { captureLogger, jsonRequest } from "../_shared/test_utils.ts";
import {
  type CheckoutConfig,
  createCheckoutHandler,
  type OrderRequest,
  type OrderSummary,
  parseCheckoutBody,
} from "./handler.ts";

const ORDER = "3f2b6c1e-8a4d-4b7e-9c2f-1a2b3c4d5e6f";
const EVENT = "e1000000-0000-4000-8000-000000000006";
const TIER = "f1000000-0000-4000-8000-000000000061";
const CONFIG: CheckoutConfig = {
  merchantId: "1211149",
  merchantSecret: "MzE5NTAzODY0MzYyMzQ0NDc5MzI5MjU2NzE2ODQ2MDAxMjY5OTE5", // test value
  mode: "sandbox",
  returnUrl: "https://example.supabase.co/functions/v1/payhere-return",
  notifyUrl: "https://example.supabase.co/functions/v1/payhere-notify",
  fallbackEmail: undefined,
};

function summary(status = "pending"): OrderSummary {
  return {
    order_id: ORDER,
    kind: "ticket",
    status,
    expires_at: "2026-10-06T10:15:00+00:00",
    summary: {
      lines: [{ label: "Lawn", quantity: 1, unit_price_minor: 150000, amount_minor: 150000 }],
      subtotal_minor: 150000,
      commission_minor: 7500,
      total_minor: 150000,
      currency: "LKR",
    },
    item_description: "Jazz Under the Stars - Lawn x1",
    customer: { first_name: "Nethmi", last_name: "Perera", email: "dev.attendee@zuno.example", city: "Colombo" },
  };
}

function setup(status = "pending") {
  const orders: OrderRequest[] = [];
  const handler = createCheckoutHandler({
    log: captureLogger(),
    authenticate: () => Promise.resolve("user-1"),
    rateLimit: () => Promise.resolve(),
    config: () => CONFIG,
    createOrder: (_userId, order) => {
      orders.push(order);
      return Promise.resolve(summary(status));
    },
  });
  return { handler, orders };
}

Deno.test("ticket checkout returns the signed PayHere form", async () => {
  const { handler, orders } = setup();
  const res = await handler(jsonRequest("https://x/functions/v1/payhere-checkout", {
    kind: "ticket",
    event_id: EVENT,
    items: [{ tier_id: TIER, quantity: 1 }],
    answers: [],
    phone: "+94771234567",
    idempotency_key: "checkout-key-001",
  }));
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(orders[0].items, [{ tier_id: TIER, quantity: 1 }]);
  assertEquals(orders[0].amountMinor, null, "client never supplies a ticket price");
  assertEquals(body.order_id, ORDER);
  assertEquals(body.status, "pending");
  assertEquals(body.summary.total_minor, 150000);
  assertEquals(body.checkout.action_url, "https://sandbox.payhere.lk/pay/checkout");
  assertEquals(body.checkout.method, "POST");
  assertEquals(body.checkout.fields.amount, "1500.00");
  assertEquals(body.checkout.fields.currency, "LKR");
  // Independently computed: md5u('1211149' + ORDER + '1500.00' + 'LKR' + md5u(secret))
  assertEquals(body.checkout.fields.hash, "F0C378448F89DBD84A3B4E6E52DAAFE4");
  assertEquals(body.checkout.fields.return_url, `${CONFIG.returnUrl}?order_id=${ORDER}`);
  assertEquals(body.checkout.fields.notify_url, CONFIG.notifyUrl);
  assertEquals(Object.keys(body.checkout.fields).sort(), [
    "address",
    "amount",
    "cancel_url",
    "city",
    "country",
    "currency",
    "email",
    "first_name",
    "hash",
    "items",
    "last_name",
    "merchant_id",
    "notify_url",
    "order_id",
    "phone",
    "return_url",
  ]);
  assertEquals("customer" in body, false, "internal customer data is not echoed");
});

Deno.test("non-pending replays are refused", async () => {
  const res = await setup("paid").handler(jsonRequest("https://x/functions/v1/payhere-checkout", {
    kind: "wallet_topup",
    amount_minor: 100000,
    phone: "0771234567",
    idempotency_key: "checkout-key-002",
  }));
  assertEquals(res.status, 409);
  assertEquals((await res.json()).error, "order_not_pending");
});

Deno.test("request validation", () => {
  const base = { phone: "+94771234567", idempotency_key: "checkout-key-003" };
  const code = (body: Record<string, unknown>) => {
    try {
      parseCheckoutBody(body, null);
      return "ok";
    } catch (err) {
      return err instanceof HttpError ? err.code : "unexpected";
    }
  };
  assertEquals(code({ ...base, kind: "donation" }), "invalid_kind");
  assertEquals(code({ ...base, kind: "ticket", event_id: EVENT, items: [] }), "invalid_items");
  assertEquals(
    code({ ...base, kind: "ticket", event_id: EVENT, items: [{ tier_id: TIER, quantity: 0 }] }),
    "invalid_items",
  );
  assertEquals(
    code({ ...base, kind: "ticket", event_id: "nope", items: [{ tier_id: TIER, quantity: 1 }] }),
    "invalid_request",
  );
  assertEquals(code({ ...base, kind: "wallet_topup", amount_minor: 10.5 }), "invalid_amount");
  assertEquals(code({ ...base, kind: "wallet_topup", amount_minor: 100000, phone: "call me" }), "invalid_phone");
  assertEquals(
    code({ kind: "wallet_topup", amount_minor: 100000, phone: "0771234567", idempotency_key: "short" }),
    "invalid_idempotency_key",
  );
  assertEquals(code({ ...base, kind: "event_creation_fee", event_id: EVENT }), "ok");
  assertEquals(
    parseCheckoutBody({ kind: "event_creation_fee", event_id: EVENT, phone: "0771234567" }, "header-key-123")
      .idempotencyKey,
    "header-key-123",
  );
  assertThrows(() =>
    parseCheckoutBody({
      ...base,
      kind: "ticket",
      event_id: EVENT,
      items: [{ tier_id: TIER, quantity: 1 }],
      answers: "x",
    }, null)
  );
});
