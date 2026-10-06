import { assertEquals } from "@std/assert";
import { HttpError } from "../_shared/http.ts";
import { captureLogger } from "../_shared/test_utils.ts";
import { type ApplyArgs, type ApplyResult, createNotifyHandler } from "./handler.ts";

const SECRET = "MzE5NTAzODY0MzYyMzQ0NDc5MzI5MjU2NzE2ODQ2MDAxMjY5OTE5"; // test value
const ORDER = "3f2b6c1e-8a4d-4b7e-9c2f-1a2b3c4d5e6f";
// Independently computed with Python hashlib (see _shared/payhere_test.ts).
const SIG_SUCCESS = "A2DFC499E35EFC66FF51715327965619";

function form(fields: Record<string, string>): Request {
  return new Request("https://example.supabase.co/functions/v1/payhere-notify", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(fields).toString(),
  });
}

const VALID = {
  merchant_id: "1211149",
  order_id: ORDER,
  payment_id: "320025071234",
  payhere_amount: "1500.00",
  payhere_currency: "LKR",
  status_code: "2",
  md5sig: SIG_SUCCESS,
  method: "VISA",
  card_holder_name: "Test Holder",
  card_no: "************1292",
};

function setup(result: ApplyResult | Error) {
  const calls: ApplyArgs[] = [];
  const log = captureLogger();
  const handler = createNotifyHandler({
    merchantId: "1211149",
    merchantSecret: SECRET,
    log,
    applyNotification: (args) => {
      calls.push(args);
      return result instanceof Error ? Promise.reject(result) : Promise.resolve(result);
    },
  });
  return { handler, calls, log };
}

const APPLIED: ApplyResult = { result: "applied", outcome: "paid", order_id: ORDER, order_status: "paid" };

Deno.test("verified notification is applied and answered with 200 ok", async () => {
  const { handler, calls, log } = setup(APPLIED);
  const res = await handler(form(VALID));
  assertEquals(res.status, 200);
  assertEquals(await res.text(), "ok");
  assertEquals(calls.length, 1);
  assertEquals(calls[0].amountMinor, 150000);
  assertEquals(calls[0].statusCode, 2);
  assertEquals(calls[0].paymentId, "320025071234");
  assertEquals("card_no" in calls[0].notification || "card_holder_name" in calls[0].notification, false);
  assertEquals(log.lines.some((l) => l.includes("1292") || l.includes("Test Holder")), false);
});

Deno.test("bad signature returns 400 and never reaches the database", async () => {
  const { handler, calls } = setup(APPLIED);
  const res = await handler(form({ ...VALID, md5sig: "0".repeat(32) }));
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, "invalid_signature");
  assertEquals(calls.length, 0);
});

Deno.test("tampered amount invalidates the signature", async () => {
  const { handler, calls } = setup(APPLIED);
  const res = await handler(form({ ...VALID, payhere_amount: "15.00" }));
  assertEquals(res.status, 400);
  assertEquals(calls.length, 0);
});

Deno.test("another merchant id is rejected", async () => {
  const { handler, calls } = setup(APPLIED);
  const res = await handler(form({ ...VALID, merchant_id: "9999999" }));
  assertEquals(res.status, 400);
  assertEquals(calls.length, 0);
});

Deno.test("verified duplicate callback still returns 200", async () => {
  const { handler } = setup({ result: "duplicate", outcome: "paid", order_id: ORDER, order_status: "paid" });
  const res = await handler(form(VALID));
  assertEquals(res.status, 200);
  assertEquals(await res.text(), "ok");
});

Deno.test("amount mismatch recorded by the database answers 400 amount_mismatch", async () => {
  const { handler } = setup({
    result: "rejected",
    outcome: "rejected_amount_mismatch",
    order_id: ORDER,
    order_status: "pending",
  });
  const res = await handler(form(VALID));
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, "amount_mismatch");
});

Deno.test("unknown order answers 404; database outage answers 500", async () => {
  assertEquals((await setup(new HttpError(404, "order_not_found")).handler(form(VALID))).status, 404);
  const outage = await setup(new HttpError(500, "internal_error")).handler(form(VALID));
  assertEquals(outage.status, 500);
  assertEquals((await outage.json()).error, "internal_error");
});

Deno.test("missing fields, JSON bodies and GET are rejected", async () => {
  const { handler } = setup(APPLIED);
  const { md5sig: _drop, ...noSig } = VALID;
  assertEquals((await handler(form(noSig))).status, 400);
  const jsonBody = new Request("https://x/functions/v1/payhere-notify", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(VALID),
  });
  assertEquals((await handler(jsonBody)).status, 415);
  assertEquals((await handler(new Request("https://x/functions/v1/payhere-notify"))).status, 405);
});

Deno.test("unconfigured merchant credentials answer 503", async () => {
  const handler = createNotifyHandler({
    merchantId: undefined,
    merchantSecret: undefined,
    log: captureLogger(),
    applyNotification: () => Promise.resolve(APPLIED),
  });
  assertEquals((await handler(form(VALID))).status, 503);
});
