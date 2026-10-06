// PayHere helpers: amount formatting, checkout hash, notification signature.
//
// Checkout hash (PayHere "Checkout API"):
//   hash = UPPER(MD5(merchant_id + order_id + amount + currency + UPPER(MD5(merchant_secret))))
//   where amount has exactly two decimals and no thousands separator ("1500.00").
// Notification signature (sent to notify_url):
//   md5sig = UPPER(MD5(merchant_id + order_id + payhere_amount + payhere_currency
//                      + status_code + UPPER(MD5(merchant_secret))))
// Money stays in integer minor units; conversion to/from the decimal string is
// done with integer arithmetic only.
import { md5Hex, timingSafeEqual } from "./crypto.ts";

export const PAYHERE_SANDBOX_CHECKOUT_URL = "https://sandbox.payhere.lk/pay/checkout";
export const PAYHERE_LIVE_CHECKOUT_URL = "https://www.payhere.lk/pay/checkout";

export function checkoutActionUrl(mode: string | undefined): string {
  return (mode ?? "sandbox").toLowerCase() === "live" ? PAYHERE_LIVE_CHECKOUT_URL : PAYHERE_SANDBOX_CHECKOUT_URL;
}

/** 150000 -> "1500.00" (integer arithmetic, no floating point). */
export function formatAmount(minor: number | bigint): string {
  const value = BigInt(minor);
  if (value < 0n) throw new RangeError("amount must not be negative");
  const units = value / 100n;
  const cents = value % 100n;
  return `${units}.${cents.toString().padStart(2, "0")}`;
}

/** "1500.00" | "1500.5" | "1500" -> 150000n; anything else -> null. */
export function parseAmountToMinor(text: string): bigint | null {
  const match = /^(\d{1,12})(?:\.(\d{1,2}))?$/.exec(text.trim());
  if (!match) return null;
  const units = BigInt(match[1]);
  const cents = BigInt((match[2] ?? "").padEnd(2, "0"));
  return units * 100n + cents;
}

async function md5Upper(value: string): Promise<string> {
  return (await md5Hex(value)).toUpperCase();
}

export async function checkoutHash(
  merchantId: string,
  orderId: string,
  amountMinor: number | bigint,
  currency: string,
  merchantSecret: string,
): Promise<string> {
  const secretHash = await md5Upper(merchantSecret);
  return md5Upper(merchantId + orderId + formatAmount(amountMinor) + currency + secretHash);
}

export interface NotifyFields {
  merchant_id: string;
  order_id: string;
  payhere_amount: string;
  payhere_currency: string;
  status_code: string;
  md5sig: string;
}

export async function notifySignature(
  fields: Omit<NotifyFields, "md5sig">,
  merchantSecret: string,
): Promise<string> {
  const secretHash = await md5Upper(merchantSecret);
  return md5Upper(
    fields.merchant_id + fields.order_id + fields.payhere_amount + fields.payhere_currency + fields.status_code +
      secretHash,
  );
}

/** Constant-time verification of md5sig. */
export async function verifyNotifySignature(fields: NotifyFields, merchantSecret: string): Promise<boolean> {
  const expected = await notifySignature(fields, merchantSecret);
  return timingSafeEqual(expected, (fields.md5sig ?? "").trim().toUpperCase());
}

/** Fields of a notification that may be stored (never card data / md5sig). */
export const STORABLE_NOTIFY_FIELDS = [
  "merchant_id",
  "order_id",
  "payment_id",
  "payhere_amount",
  "payhere_currency",
  "status_code",
  "status_message",
  "method",
  "captured_amount",
  "recurring",
] as const;

export function sanitizeNotification(form: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const key of STORABLE_NOTIFY_FIELDS) {
    if (typeof form[key] === "string") out[key] = form[key].slice(0, 200);
  }
  return out;
}
