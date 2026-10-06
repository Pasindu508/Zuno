import type { SupabaseClient } from "@supabase/supabase-js";
import { type ApnsEnvironment, ApnsTokenCache, buildApnsPayload, importApnsKey, sendApns } from "../_shared/apns.ts";
import { optionalEnv, requireEnv } from "../_shared/env.ts";
import { dbError } from "../_shared/http.ts";
import { createLogger } from "../_shared/log.ts";
import { createAdminClient, isServiceRoleRequest } from "../_shared/supabase.ts";
import { createPushHandler, type Device, type Preference } from "./handler.ts";

const log = createLogger("push-dispatch");
let admin: SupabaseClient | null = null;
const client = () => (admin ??= createAdminClient());
let tokens: ApnsTokenCache | null = null;

async function providerToken(): Promise<string> {
  if (!tokens) {
    const key = await importApnsKey(requireEnv("APNS_KEY_P8", "push_unavailable"));
    tokens = new ApnsTokenCache(
      key,
      requireEnv("APNS_KEY_ID", "push_unavailable"),
      requireEnv("APNS_TEAM_ID", "push_unavailable"),
    );
  }
  return tokens.get();
}

Deno.serve(createPushHandler({
  log,
  isServiceRole: isServiceRoleRequest,
  loadPreferences: async (userIds) => {
    if (userIds.length === 0) return [];
    const { data, error } = await client()
      .from("notification_preferences")
      .select(
        "user_id, push_enabled, event_reminders, payment_updates, event_changes, waitlist_updates, organizer_news",
      )
      .in("user_id", userIds);
    if (error) throw dbError(error);
    return (data ?? []) as Preference[];
  },
  loadDevices: async (userIds) => {
    if (userIds.length === 0) return [];
    const { data, error } = await client()
      .from("push_devices")
      .select("id, user_id, apns_token, environment")
      .in("user_id", userIds);
    if (error) throw dbError(error);
    return (data ?? []) as Device[];
  },
  send: async (device, message) => {
    const topic = requireEnv("APNS_TOPIC", "push_unavailable");
    const fallbackEnv = (optionalEnv("APNS_ENV") ?? "production") as ApnsEnvironment;
    const environment: ApnsEnvironment = device.environment === "sandbox" || device.environment === "production"
      ? device.environment
      : fallbackEnv;
    return sendApns(device.apns_token, environment, await providerToken(), topic, buildApnsPayload(message));
  },
  removeDevices: async (ids) => {
    const { error } = await client().from("push_devices").delete().in("id", ids);
    if (error) throw dbError(error);
  },
}));
