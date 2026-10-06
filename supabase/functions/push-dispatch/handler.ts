// push-dispatch: APNs fan-out. SERVICE ROLE ONLY (bearer must equal the
// service-role key). Accepts either the contract body
//   { "user_ids": [...], "title", "body", "data" }
// or a Supabase Database Webhook payload for INSERT on public.notifications
//   { "type": "INSERT", "table": "notifications", "record": {...} }.
// Respects notification_preferences (push_enabled + per-category switches)
// and removes device tokens APNs reports as unregistered.
import type { ApnsEnvironment, ApnsResult, PushMessage } from "../_shared/apns.ts";
import { HttpError, isUuid, json, readJsonObject, requireMethod, withErrorHandling } from "../_shared/http.ts";
import type { Logger } from "../_shared/log.ts";

export interface Preference {
  user_id: string;
  push_enabled: boolean;
  event_reminders: boolean;
  payment_updates: boolean;
  event_changes: boolean;
  waitlist_updates: boolean;
  organizer_news: boolean;
}

export interface Device {
  id: string;
  user_id: string;
  apns_token: string;
  environment: ApnsEnvironment;
}

export interface PushDeps {
  isServiceRole(req: Request): boolean;
  loadPreferences(userIds: string[]): Promise<Preference[]>;
  loadDevices(userIds: string[]): Promise<Device[]>;
  send(device: Device, message: PushMessage): Promise<ApnsResult>; // throws HttpError 503 if APNs unconfigured
  removeDevices(ids: string[]): Promise<void>;
  log: Logger;
}

/** Which preference switch governs a notification kind (null = always allowed). */
export function preferenceFor(kind: string | undefined): keyof Omit<Preference, "user_id" | "push_enabled"> | null {
  switch (kind) {
    case "event_reminder":
      return "event_reminders";
    case "payment_status":
    case "refund_status":
      return "payment_updates";
    case "venue_change":
    case "schedule_change":
    case "event_cancelled":
      return "event_changes";
    case "waitlist_movement":
      return "waitlist_updates";
    case "organizer_update":
      return "organizer_news";
    default:
      return null;
  }
}

export interface DispatchRequest {
  userIds: string[];
  message: PushMessage;
  kind?: string;
}

export function parsePushBody(body: Record<string, unknown>): DispatchRequest {
  if (body.type !== undefined && body.record !== undefined) {
    // Database Webhook payload
    const record = body.record as Record<string, unknown> | null;
    if (body.type !== "INSERT" || body.table !== "notifications" || !record || !isUuid(record.user_id)) {
      throw new HttpError(400, "invalid_request", "Unsupported webhook payload.");
    }
    const data: Record<string, unknown> = {
      notification_id: record.id,
      kind: record.kind,
      event_id: record.event_id ?? null,
      ...(typeof record.data === "object" && record.data !== null ? record.data as Record<string, unknown> : {}),
    };
    return {
      userIds: [record.user_id as string],
      kind: typeof record.kind === "string" ? record.kind : undefined,
      message: {
        title: String(record.title ?? "").slice(0, 200),
        body: String(record.body ?? "").slice(0, 2000),
        data,
      },
    };
  }
  const { user_ids: userIds, title, body: text, data } = body;
  if (!Array.isArray(userIds) || userIds.length < 1 || userIds.length > 1000 || !userIds.every(isUuid)) {
    throw new HttpError(400, "invalid_request", "user_ids must be 1-1000 UUIDs.");
  }
  if (typeof title !== "string" || title.length < 1 || title.length > 200) {
    throw new HttpError(400, "invalid_request", "title must be 1-200 characters.");
  }
  if (typeof text !== "string" || text.length > 2000) {
    throw new HttpError(400, "invalid_request", "body must be a string.");
  }
  if (data !== undefined && (data === null || typeof data !== "object" || Array.isArray(data))) {
    throw new HttpError(400, "invalid_request", "data must be an object.");
  }
  const kind = data && typeof (data as Record<string, unknown>).kind === "string"
    ? (data as Record<string, string>).kind
    : undefined;
  return {
    userIds: [...new Set(userIds as string[])],
    kind,
    message: { title, body: text, data: data as Record<string, unknown> | undefined },
  };
}

export function createPushHandler(deps: PushDeps): (req: Request) => Promise<Response> {
  return withErrorHandling(deps.log, async (req) => {
    requireMethod(req, "POST");
    if (!deps.isServiceRole(req)) {
      throw new HttpError(403, "forbidden", "push-dispatch is restricted to the service role.");
    }
    const request = parsePushBody(await readJsonObject(req, 32 * 1024));

    const preferenceKey = preferenceFor(request.kind);
    const preferences = await deps.loadPreferences(request.userIds);
    const allowed = new Set(
      preferences
        .filter((p) => p.push_enabled && (preferenceKey === null || p[preferenceKey]))
        .map((p) => p.user_id),
    );
    const devices = (await deps.loadDevices([...allowed])).filter((d) => allowed.has(d.user_id));

    let sent = 0;
    let failed = 0;
    const stale: string[] = [];
    for (const device of devices) {
      try {
        const result = await deps.send(device, request.message);
        if (result.status === 200) sent++;
        else {
          failed++;
          if (result.unregistered) stale.push(device.id);
        }
      } catch (err) {
        if (err instanceof HttpError) throw err; // configuration problems
        failed++;
        deps.log.warn("apns send failed", {
          device_id: device.id,
          error: err instanceof Error ? err.message : "unknown",
        });
      }
    }
    if (stale.length > 0) await deps.removeDevices(stale);
    deps.log.info("push dispatched", {
      users: request.userIds.length,
      devices: devices.length,
      sent,
      failed,
      removed: stale.length,
    });
    return json({ sent, failed, removed: stale.length, skipped_users: request.userIds.length - allowed.size });
  });
}
