// ai-organizer-copilot: drafts an agenda or registration questions for an
// event the caller owns. Drafts are stored in public.ai_drafts and are only
// suggestions; the organizer applies them to the draft event explicitly.
import {
  type AgendaItem,
  AI_HTTP_STATUS,
  AiError,
  type DraftKind,
  type EventContext,
  type QuestionDraft,
  validateAgendaOutput,
  validateQuestionsOutput,
} from "../_shared/ai.ts";
import { HttpError, json, readJsonObject, requireMethod, requireUuid, withErrorHandling } from "../_shared/http.ts";
import type { Logger } from "../_shared/log.ts";
import { RATE_LIMITS, type RateLimitRule } from "../_shared/ratelimit.ts";

export interface OwnedEvent {
  id: string;
  organizer_id: string;
  owner_id: string | null;
  context: EventContext;
}

export interface StoredDraft {
  id: string;
  kind: DraftKind;
  status: string;
  content: { agenda?: AgendaItem[]; questions?: QuestionDraft[] } | null;
}

export interface CopilotDeps {
  authenticate(req: Request): Promise<string>;
  rateLimit(key: string, rule: RateLimitRule): Promise<void>;
  loadEvent(eventId: string): Promise<OwnedEvent | null>;
  findDraft(eventId: string, requestId: string): Promise<StoredDraft | null>;
  generate(kind: DraftKind, event: EventContext, instructions: string | null): Promise<unknown>; // raw structured output
  saveDraft(draft: {
    event_id: string;
    organizer_id: string;
    kind: DraftKind;
    status: "succeeded" | "failed";
    request_id: string;
    instructions: string | null;
    content: Record<string, unknown> | null;
    error_code: string | null;
    created_by: string;
  }): Promise<string>;
  log: Logger;
}

export function parseCopilotBody(body: Record<string, unknown>) {
  const eventId = requireUuid(body.event_id, "event_id");
  const kind = body.kind;
  if (kind !== "agenda" && kind !== "questions") {
    throw new HttpError(400, "invalid_kind", "kind must be agenda or questions.");
  }
  const requestId = body.request_id;
  if (typeof requestId !== "string" || !/^[A-Za-z0-9_.:-]{8,100}$/.test(requestId)) {
    throw new HttpError(400, "invalid_request", "request_id must be 8-100 characters [A-Za-z0-9_.:-].");
  }
  let instructions: string | null = null;
  if (body.instructions !== undefined && body.instructions !== null) {
    if (typeof body.instructions !== "string" || body.instructions.length > 1000) {
      throw new HttpError(400, "invalid_request", "instructions must be a string of at most 1000 characters.");
    }
    instructions = body.instructions.trim() || null;
  }
  return { eventId, kind: kind as DraftKind, requestId, instructions };
}

function responseFor(
  draftId: string,
  kind: DraftKind,
  content: { agenda?: AgendaItem[]; questions?: QuestionDraft[] },
) {
  return kind === "agenda"
    ? { draft_id: draftId, kind, status: "succeeded", agenda: content.agenda ?? [] }
    : { draft_id: draftId, kind, status: "succeeded", questions: content.questions ?? [] };
}

export function createCopilotHandler(deps: CopilotDeps): (req: Request) => Promise<Response> {
  return withErrorHandling(deps.log, async (req) => {
    requireMethod(req, "POST");
    const userId = await deps.authenticate(req);
    const { eventId, kind, requestId, instructions } = parseCopilotBody(await readJsonObject(req, 8 * 1024));

    const event = await deps.loadEvent(eventId);
    if (!event || event.owner_id !== userId) throw new HttpError(403, "not_owner", "You do not manage this event.");

    // Idempotent per (event, request_id): a finished draft is returned as is.
    const existing = await deps.findDraft(eventId, requestId);
    if (existing && existing.status !== "failed" && existing.content) {
      return json(responseFor(existing.id, existing.kind, existing.content));
    }

    await deps.rateLimit(`ai:${userId}`, RATE_LIMITS.aiCopilot);

    let content: { agenda?: AgendaItem[]; questions?: QuestionDraft[] };
    try {
      const raw = await deps.generate(kind, event.context, instructions);
      content = kind === "agenda"
        ? { agenda: validateAgendaOutput(raw, event.context.starts_at, event.context.ends_at) }
        : { questions: validateQuestionsOutput(raw) };
    } catch (err) {
      if (err instanceof AiError) {
        deps.log.warn("ai draft failed", { event_id: eventId, kind, code: err.code, reason: err.message });
        try {
          await deps.saveDraft({
            event_id: eventId,
            organizer_id: event.organizer_id,
            kind,
            status: "failed",
            request_id: requestId,
            instructions,
            content: null,
            error_code: err.code,
            created_by: userId,
          });
        } catch (saveErr) {
          deps.log.error("could not record failed draft", {
            error: saveErr instanceof Error ? saveErr.message : "unknown",
          });
        }
        throw new HttpError(AI_HTTP_STATUS[err.code], err.code, messageFor(err.code));
      }
      throw err;
    }

    const draftId = await deps.saveDraft({
      event_id: eventId,
      organizer_id: event.organizer_id,
      kind,
      status: "succeeded",
      request_id: requestId,
      instructions,
      content,
      error_code: null,
      created_by: userId,
    });
    deps.log.info("ai draft created", { event_id: eventId, kind, draft_id: draftId });
    return json(responseFor(draftId, kind, content));
  });
}

function messageFor(code: AiError["code"]): string {
  switch (code) {
    case "ai_timeout":
      return "The assistant took too long. Please try again.";
    case "ai_refused":
      return "The assistant could not help with this request.";
    case "ai_malformed":
      return "The assistant returned an unusable draft. Please try again.";
    case "ai_unavailable":
      return "The assistant is unavailable right now.";
  }
}
