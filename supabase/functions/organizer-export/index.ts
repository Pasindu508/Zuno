import type { SupabaseClient } from "@supabase/supabase-js";
import { json, readJsonObject, requireMethod, requireUuid, withErrorHandling } from "../_shared/http.ts";
import { createLogger } from "../_shared/log.ts";
import { enforceRateLimit, RATE_LIMITS } from "../_shared/ratelimit.ts";
import { authenticateUser, callRpc, createAdminClient } from "../_shared/supabase.ts";
import { buildExportCsv, type ExportData } from "./handler.ts";

const log = createLogger("organizer-export");
let admin: SupabaseClient | null = null;
const client = () => (admin ??= createAdminClient());

Deno.serve(withErrorHandling(log, async (req) => {
  requireMethod(req, "POST");
  const user = await authenticateUser(req, client());
  await enforceRateLimit(client(), `export:${user.id}`, RATE_LIMITS.organizerExport);
  const body = await readJsonObject(req, 1024);
  const eventId = requireUuid(body.event_id, "event_id");

  // organizer_export_data checks ownership (not_owner) and audits the export.
  const data = await callRpc<ExportData>(client(), "organizer_export_data", {
    p_user_id: user.id,
    p_event_id: eventId,
  });
  const result = buildExportCsv(data);
  log.info("attendee export", { user_id: user.id, event_id: eventId, rows: data.rows.length });
  return json(result);
}));
