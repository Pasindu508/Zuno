import type { SupabaseClient } from "@supabase/supabase-js";
import {
  AGENDA_SCHEMA,
  AiError,
  buildUserPrompt,
  callAnthropic,
  DEFAULT_AI_MODEL,
  QUESTIONS_SCHEMA,
  SYSTEM_PROMPT,
} from "../_shared/ai.ts";
import { optionalEnv } from "../_shared/env.ts";
import { dbError } from "../_shared/http.ts";
import { createLogger } from "../_shared/log.ts";
import { enforceRateLimit } from "../_shared/ratelimit.ts";
import { authenticateUser, createAdminClient } from "../_shared/supabase.ts";
import { createCopilotHandler, type OwnedEvent, type StoredDraft } from "./handler.ts";

const log = createLogger("ai-organizer-copilot");
let admin: SupabaseClient | null = null;
const client = () => (admin ??= createAdminClient());

interface EventRow {
  id: string;
  organizer_id: string;
  title: string;
  summary: string;
  description: string;
  format: string;
  starts_at: string;
  ends_at: string;
  tags: string[];
  categories: { name: string } | null;
  organizer_profiles: { owner_id: string | null } | null;
}

Deno.serve(createCopilotHandler({
  log,
  authenticate: async (req) => (await authenticateUser(req, client())).id,
  rateLimit: (key, rule) => enforceRateLimit(client(), key, rule),
  loadEvent: async (eventId): Promise<OwnedEvent | null> => {
    const { data, error } = await client()
      .from("events")
      .select(
        "id, organizer_id, title, summary, description, format, starts_at, ends_at, tags, categories(name), organizer_profiles(owner_id)",
      )
      .eq("id", eventId)
      .maybeSingle<EventRow>();
    if (error) throw dbError(error);
    if (!data) return null;
    return {
      id: data.id,
      organizer_id: data.organizer_id,
      owner_id: data.organizer_profiles?.owner_id ?? null,
      context: {
        title: data.title,
        summary: data.summary,
        description: data.description,
        format: data.format,
        category: data.categories?.name ?? "",
        starts_at: data.starts_at,
        ends_at: data.ends_at,
        tags: data.tags ?? [],
      },
    };
  },
  findDraft: async (eventId, requestId): Promise<StoredDraft | null> => {
    const { data, error } = await client()
      .from("ai_drafts")
      .select("id, kind, status, content")
      .eq("event_id", eventId)
      .eq("request_id", requestId)
      .maybeSingle<StoredDraft>();
    if (error) throw dbError(error);
    return data;
  },
  generate: (kind, event, instructions) => {
    const apiKey = optionalEnv("ANTHROPIC_API_KEY");
    if (!apiKey) throw new AiError("ai_unavailable", "ANTHROPIC_API_KEY is not configured");
    return callAnthropic({
      apiKey,
      model: optionalEnv("AI_MODEL") ?? DEFAULT_AI_MODEL,
      effort: optionalEnv("AI_EFFORT"),
      fallbacks: (optionalEnv("AI_FALLBACKS") ?? "default") !== "off",
      system: SYSTEM_PROMPT,
      prompt: buildUserPrompt(kind, event, instructions),
      schema: kind === "agenda" ? AGENDA_SCHEMA : QUESTIONS_SCHEMA,
    });
  },
  saveDraft: async (draft) => {
    const { data, error } = await client()
      .from("ai_drafts")
      .upsert({ ...draft, model: optionalEnv("AI_MODEL") ?? DEFAULT_AI_MODEL }, { onConflict: "event_id,request_id" })
      .select("id")
      .single<{ id: string }>();
    if (error) throw dbError(error);
    return data.id;
  },
}));
