// payhere-notify: PayHere server-to-server notification (form POST).
// No user JWT (verify_jwt = false). Trust comes only from md5sig, verified in
// constant time with the merchant secret, plus amount/currency equality with
// the order (checked again inside apply_payhere_notification).
import { errorResponse, HttpError, isUuid, withErrorHandling } from "../_shared/http.ts";
import type { Logger } from "../_shared/log.ts";
import { parseAmountToMinor, sanitizeNotification, verifyNotifySignature } from "../_shared/payhere.ts";

export interface ApplyArgs {
  orderId: string;
  paymentId: string;
  statusCode: number;
  amountMinor: number; // integer minor units (< 2^53 by construction: max 12 integer digits)
  currency: string;
  method: string | null;
  notification: Record<string, string>;
}

export interface ApplyResult {
  result: "applied" | "duplicate" | "rejected";
  outcome: string;
  order_id: string;
  order_status: string;
}

export interface NotifyDeps {
  merchantId: string | undefined;
  merchantSecret: string | undefined;
  applyNotification(args: ApplyArgs): Promise<ApplyResult>;
  log: Logger;
}

const REQUIRED = ["merchant_id", "order_id", "payhere_amount", "payhere_currency", "status_code", "md5sig"] as const;

function okText(): Response {
  return new Response("ok", { status: 200, headers: { "Content-Type": "text/plain; charset=utf-8" } });
}

export async function readForm(req: Request): Promise<Record<string, string>> {
  const contentType = (req.headers.get("content-type") ?? "").toLowerCase();
  const form: Record<string, string> = {};
  if (contentType.includes("application/x-www-form-urlencoded")) {
    const params = new URLSearchParams(await req.text());
    for (const [key, value] of params) form[key] = value;
  } else if (contentType.includes("multipart/form-data")) {
    const data = await req.formData();
    for (const [key, value] of data) if (typeof value === "string") form[key] = value;
  } else {
    throw new HttpError(415, "invalid_request", "Expected a form-encoded PayHere notification.");
  }
  return form;
}

export function createNotifyHandler(deps: NotifyDeps): (req: Request) => Promise<Response> {
  return withErrorHandling(deps.log, async (req) => {
    if (req.method !== "POST") throw new HttpError(405, "method_not_allowed", "Use POST.");
    if (!deps.merchantId || !deps.merchantSecret) {
      throw new HttpError(503, "payments_unavailable", "PayHere is not configured.");
    }
    const form = await readForm(req);
    for (const key of REQUIRED) {
      if (typeof form[key] !== "string" || form[key].trim() === "") {
        throw new HttpError(400, "invalid_request", `Missing field ${key}.`);
      }
    }
    if (form.merchant_id !== deps.merchantId) {
      deps.log.warn("notification for another merchant", { order_id: form.order_id });
      return errorResponse(400, "invalid_signature", "Merchant mismatch.");
    }

    const verified = await verifyNotifySignature({
      merchant_id: form.merchant_id,
      order_id: form.order_id,
      payhere_amount: form.payhere_amount,
      payhere_currency: form.payhere_currency,
      status_code: form.status_code,
      md5sig: form.md5sig,
    }, deps.merchantSecret);
    if (!verified) {
      deps.log.warn("invalid md5sig", { order_id: form.order_id, status_code: form.status_code });
      return errorResponse(400, "invalid_signature", "Signature verification failed.");
    }

    // Everything below runs only for a verified notification.
    if (!isUuid(form.order_id)) return errorResponse(400, "invalid_request", "Unknown order id format.");
    const amountMinor = parseAmountToMinor(form.payhere_amount);
    if (amountMinor === null) return errorResponse(400, "invalid_request", "Invalid payhere_amount.");
    const statusCode = Number.parseInt(form.status_code, 10);
    if (!Number.isInteger(statusCode) || String(statusCode) !== form.status_code.trim()) {
      return errorResponse(400, "invalid_request", "Invalid status_code.");
    }

    let result: ApplyResult;
    try {
      result = await deps.applyNotification({
        orderId: form.order_id.toLowerCase(),
        paymentId: (form.payment_id ?? "").trim(),
        statusCode,
        amountMinor: Number(amountMinor),
        currency: form.payhere_currency.trim().toUpperCase(),
        method: form.method ?? null,
        notification: sanitizeNotification(form),
      });
    } catch (err) {
      if (err instanceof HttpError && err.code === "order_not_found") {
        deps.log.warn("verified notification for unknown order", { order_id: form.order_id });
        return errorResponse(404, "order_not_found", "Unknown order.");
      }
      throw err; // 500: PayHere may retry; the RPC is idempotent.
    }

    deps.log.info("notification processed", {
      order_id: result.order_id,
      status_code: statusCode,
      result: result.result,
      outcome: result.outcome,
      order_status: result.order_status,
    });
    if (result.result === "rejected") {
      const code = result.outcome === "rejected_amount_mismatch" ? "amount_mismatch" : "rejected";
      return errorResponse(400, code, "Notification recorded but not applied.");
    }
    // Applied, or a verified duplicate: always 200 so PayHere stops retrying.
    return okText();
  });
}
