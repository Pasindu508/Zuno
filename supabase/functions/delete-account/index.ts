// delete-account: permanently deletes the caller's account.
// 1. prepare_account_deletion (service role) validates and returns the storage
//    prefixes to remove (refuses organizers with live events);
// 2. storage objects under avatars/<uid>/ and event-media/<organizer_id>/ are removed;
// 3. auth.admin.deleteUser - the BEFORE DELETE trigger on auth.users then
//    anonymises retained financial records atomically with the deletion.
import type { SupabaseClient } from "@supabase/supabase-js";
import { HttpError, json, readJsonObject, requireMethod, withErrorHandling } from "../_shared/http.ts";
import { createLogger } from "../_shared/log.ts";
import { enforceRateLimit, RATE_LIMITS } from "../_shared/ratelimit.ts";
import { authenticateUser, callRpc, createAdminClient } from "../_shared/supabase.ts";

const log = createLogger("delete-account");
let admin: SupabaseClient | null = null;
const client = () => (admin ??= createAdminClient());

/** Lists every object path below `prefix` (recursing into folders). */
export async function listObjects(
  storage: SupabaseClient["storage"],
  bucket: string,
  prefix: string,
): Promise<string[]> {
  const paths: string[] = [];
  const pageSize = 1000;
  for (let offset = 0;; offset += pageSize) {
    const { data, error } = await storage.from(bucket).list(prefix, { limit: pageSize, offset });
    if (error) throw new HttpError(500, "storage_error", "Could not list stored files.");
    for (const entry of data ?? []) {
      const path = `${prefix}/${entry.name}`;
      if (entry.id === null) paths.push(...await listObjects(storage, bucket, path)); // folder
      else paths.push(path);
    }
    if (!data || data.length < pageSize) break;
  }
  return paths;
}

async function removePrefix(bucket: string, prefix: string): Promise<number> {
  const storage = client().storage;
  const paths = await listObjects(storage, bucket, prefix);
  for (let i = 0; i < paths.length; i += 100) {
    const { error } = await storage.from(bucket).remove(paths.slice(i, i + 100));
    if (error) throw new HttpError(500, "storage_error", "Could not remove stored files.");
  }
  return paths.length;
}

Deno.serve(withErrorHandling(log, async (req) => {
  requireMethod(req, "POST");
  const user = await authenticateUser(req, client());
  await enforceRateLimit(client(), `delete:${user.id}`, RATE_LIMITS.deleteAccount);
  const body = await readJsonObject(req, 1024);
  if (body.confirm !== "DELETE") {
    throw new HttpError(400, "confirmation_required", 'Send {"confirm": "DELETE"} to delete your account.');
  }

  const plan = await callRpc<{ avatar_prefix: string; organizer_ids: string[] }>(
    client(),
    "prepare_account_deletion",
    { p_user_id: user.id },
  );

  let removed = await removePrefix("avatars", plan.avatar_prefix);
  for (const organizerId of plan.organizer_ids ?? []) {
    removed += await removePrefix("event-media", organizerId);
  }

  const { error } = await client().auth.admin.deleteUser(user.id);
  if (error) {
    log.error("auth user deletion failed", { user_id: user.id, error: error.message });
    throw new HttpError(500, "internal_error", "Account deletion failed; please try again.");
  }
  log.info("account deleted", { user_id: user.id, storage_objects_removed: removed });
  return json({ status: "deleted" });
}));
