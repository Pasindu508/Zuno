// Vectors computed independently with Python's hashlib:
//   md5u = lambda s: hashlib.md5(s.encode()).hexdigest().upper()
//   md5u('1211149' + 'ItemNo12345' + '1000.00' + 'LKR' + md5u(secret))
import { assertEquals, assertThrows } from "@std/assert";
import {
  checkoutActionUrl,
  checkoutHash,
  formatAmount,
  notifySignature,
  parseAmountToMinor,
  sanitizeNotification,
  verifyNotifySignature,
} from "./payhere.ts";
import { md5Hex } from "./crypto.ts";

const SECRET = "MzE5NTAzODY0MzYyMzQ0NDc5MzI5MjU2NzE2ODQ2MDAxMjY5OTE5"; // test value, not a real secret
const ORDER = "3f2b6c1e-8a4d-4b7e-9c2f-1a2b3c4d5e6f";

Deno.test("md5Hex matches the RFC 1321 empty-string vector", async () => {
  assertEquals(await md5Hex(""), "d41d8cd98f00b204e9800998ecf8427e");
});

Deno.test("formatAmount uses exactly two decimals without separators", () => {
  assertEquals(formatAmount(100000), "1000.00");
  assertEquals(formatAmount(150050), "1500.50");
  assertEquals(formatAmount(5), "0.05");
  assertEquals(formatAmount(0), "0.00");
  assertEquals(formatAmount(500000000n), "5000000.00");
  assertThrows(() => formatAmount(-1));
});

Deno.test("parseAmountToMinor converts PayHere amounts exactly (no floats)", () => {
  assertEquals(parseAmountToMinor("1500.00"), 150000n);
  assertEquals(parseAmountToMinor("1500.5"), 150050n);
  assertEquals(parseAmountToMinor("1500"), 150000n);
  assertEquals(parseAmountToMinor("0.01"), 1n);
  assertEquals(parseAmountToMinor("19.99"), 1999n);
  assertEquals(parseAmountToMinor("1,500.00"), null);
  assertEquals(parseAmountToMinor("-1.00"), null);
  assertEquals(parseAmountToMinor("1.005"), null);
  assertEquals(parseAmountToMinor("abc"), null);
});

Deno.test("checkout hash matches the independently computed vector", async () => {
  assertEquals(await checkoutHash("1211149", "ItemNo12345", 100000, "LKR", SECRET), "06F17728997FE304CB1AF127A94226D9");
  assertEquals(await checkoutHash("1211149", ORDER, 150000, "LKR", SECRET), "F0C378448F89DBD84A3B4E6E52DAAFE4");
});

Deno.test("notify md5sig matches the independently computed vector", async () => {
  const fields = {
    merchant_id: "1211149",
    order_id: ORDER,
    payhere_amount: "1500.00",
    payhere_currency: "LKR",
    status_code: "2",
  };
  assertEquals(await notifySignature(fields, SECRET), "A2DFC499E35EFC66FF51715327965619");
  assertEquals(await notifySignature({ ...fields, status_code: "-2" }, SECRET), "426EC1887EAA94B92C88387A64B118D2");
});

Deno.test("verifyNotifySignature accepts valid (case-insensitive) and rejects tampered notifications", async () => {
  const base = {
    merchant_id: "1211149",
    order_id: ORDER,
    payhere_amount: "1500.00",
    payhere_currency: "LKR",
    status_code: "2",
    md5sig: "A2DFC499E35EFC66FF51715327965619",
  };
  assertEquals(await verifyNotifySignature(base, SECRET), true);
  assertEquals(await verifyNotifySignature({ ...base, md5sig: base.md5sig.toLowerCase() }, SECRET), true);
  assertEquals(await verifyNotifySignature({ ...base, payhere_amount: "15.00" }, SECRET), false);
  assertEquals(await verifyNotifySignature({ ...base, status_code: "-2" }, SECRET), false);
  assertEquals(await verifyNotifySignature(base, "wrong-secret"), false);
  assertEquals(await verifyNotifySignature({ ...base, md5sig: "" }, SECRET), false);
});

Deno.test("sanitizeNotification keeps only allow-listed fields", () => {
  const clean = sanitizeNotification({
    merchant_id: "1211149",
    order_id: ORDER,
    payment_id: "320025071234",
    payhere_amount: "1500.00",
    payhere_currency: "LKR",
    status_code: "2",
    md5sig: "A2DF...",
    card_holder_name: "Test Holder",
    card_no: "************1292",
    card_expiry: "12/30",
    method: "VISA",
  });
  assertEquals(Object.keys(clean).sort(), [
    "merchant_id",
    "method",
    "order_id",
    "payhere_amount",
    "payhere_currency",
    "payment_id",
    "status_code",
  ]);
});

Deno.test("checkoutActionUrl switches between sandbox and live", () => {
  assertEquals(checkoutActionUrl(undefined), "https://sandbox.payhere.lk/pay/checkout");
  assertEquals(checkoutActionUrl("sandbox"), "https://sandbox.payhere.lk/pay/checkout");
  assertEquals(checkoutActionUrl("live"), "https://www.payhere.lk/pay/checkout");
});
