// HTTP helpers: CORS, JSON responses with the contract error shape
// `{ "error": "<code>", "message": "..." }`, request parsing and error mapping.
import type { Logger } from "./log.ts";

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, idempotency-key",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
  "Access-Control-Max-Age": "86400",
};

export class HttpError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message?: string,
  ) {
    super(message ?? code);
    this.name = "HttpError";
  }
}

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...headers,
    },
  });
}

export function errorResponse(status: number, code: string, message: string): Response {
  return json({ error: code, message }, status);
}

export function handleOptions(req: Request): Response | null {
  return req.method === "OPTIONS" ? new Response("ok", { headers: corsHeaders }) : null;
}

export function requireMethod(req: Request, ...methods: string[]): void {
  if (!methods.includes(req.method)) {
    throw new HttpError(405, "method_not_allowed", `Use ${methods.join(" or ")}.`);
  }
}

/** Parses a JSON object body (max 64 KiB by default). */
export async function readJsonObject(req: Request, maxBytes = 64 * 1024): Promise<Record<string, unknown>> {
  const contentType = req.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().includes("application/json")) {
    throw new HttpError(415, "invalid_request", "Content-Type must be application/json.");
  }
  const text = await req.text();
  if (new TextEncoder().encode(text).length > maxBytes) {
    throw new HttpError(413, "invalid_request", "Request body is too large.");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new HttpError(400, "invalid_request", "Body is not valid JSON.");
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new HttpError(400, "invalid_request", "Body must be a JSON object.");
  }
  return parsed as Record<string, unknown>;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_RE.test(value);
}

export function requireUuid(value: unknown, field: string, code = "invalid_request"): string {
  if (!isUuid(value)) throw new HttpError(400, code, `${field} must be a UUID.`);
  return value.toLowerCase();
}

// ---------------------------------------------------------------------------
// Database (RPC) error mapping. RPCs raise `RAISE EXCEPTION ... MESSAGE = '<code>'`
// with SQLSTATE P0001; PostgREST returns { code: "P0001", message: "<code>" }.
// ---------------------------------------------------------------------------
const STATUS_BY_DB_CODE: Record<string, number> = {
  not_authenticated: 401,
  not_owner: 403,
  not_authorized: 403,
  organizer_not_verified: 403,
  identity_required: 403,
  event_not_found: 404,
  order_not_found: 404,
  user_not_found: 404,
  registration_not_found: 404,
  sold_out: 409,
  already_registered: 409,
  already_verified: 409,
  idempotency_conflict: 409,
  creation_fee_already_paid: 409,
  creation_fee_unpaid: 409,
  registration_closed: 409,
  event_not_editable: 409,
  organizer_has_active_events: 409,
  fee_changed: 409,
  insufficient_balance: 409,
  rate_limited: 429,
  invalid_items: 400,
  invalid_amount: 400,
  invalid_kind: 400,
  invalid_request: 400,
  invalid_idempotency_key: 400,
  invalid_digest: 400,
  invalid_key_version: 400,
  answers_invalid: 400,
  max_per_order_exceeded: 400,
  tier_not_on_sale: 409,
  not_paid_event: 400,
  not_free_event: 400,
  validation_failed: 422,
};

export interface DbErrorLike {
  code?: string;
  message?: string;
  details?: string | null;
}

/** Converts a PostgREST/RPC error into an HttpError without leaking internals. */
export function dbError(error: DbErrorLike): HttpError {
  const code = error.message ?? "";
  if (error.code === "P0001" && code in STATUS_BY_DB_CODE) {
    const detail = error.details ? ` (${error.details})` : "";
    return new HttpError(STATUS_BY_DB_CODE[code], code, `Request rejected: ${code}${detail}.`);
  }
  return new HttpError(500, "internal_error", "Unexpected server error.");
}

/** Wraps a handler: OPTIONS, HttpError -> contract error body, unknown -> 500. */
export function withErrorHandling(
  log: Logger,
  handler: (req: Request) => Promise<Response>,
): (req: Request) => Promise<Response> {
  return async (req: Request) => {
    const preflight = handleOptions(req);
    if (preflight) return preflight;
    try {
      return await handler(req);
    } catch (err) {
      if (err instanceof HttpError) {
        if (err.status >= 500) log.error("request failed", { code: err.code, status: err.status });
        else log.info("request rejected", { code: err.code, status: err.status });
        return errorResponse(err.status, err.code, err.message);
      }
      log.error("unhandled error", { error: err instanceof Error ? err.message : String(err) });
      return errorResponse(500, "internal_error", "Unexpected server error.");
    }
  };
}
