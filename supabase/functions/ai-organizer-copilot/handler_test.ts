import { assertEquals } from "@std/assert";
import { AiError } from "../_shared/ai.ts";
import { captureLogger, jsonRequest } from "../_shared/test_utils.ts";
import { type CopilotDeps, createCopilotHandler, type StoredDraft } from "./handler.ts";

const EVENT = "e1000000-0000-4000-8000-000000000002";
const URL_ = "https://x/functions/v1/ai-organizer-copilot";

function setup(generate: CopilotDeps["generate"], opts: { owner?: string; existing?: StoredDraft } = {}) {
  const saved: Parameters<CopilotDeps["saveDraft"]>[0][] = [];
  let generated = 0;
  const handler = createCopilotHandler({
    log: captureLogger(),
    authenticate: () => Promise.resolve("owner-1"),
    rateLimit: () => Promise.resolve(),
    loadEvent: () =>
      Promise.resolve({
        id: EVENT,
        organizer_id: "org-1",
        owner_id: opts.owner ?? "owner-1",
        context: {
          title: "Native iOS with SwiftUI",
          summary: "A hands-on afternoon",
          description: "Learn SwiftUI.",
          format: "physical",
          category: "Workshops",
          starts_at: "2026-10-08T08:30:00Z",
          ends_at: "2026-10-08T11:30:00Z",
          tags: ["swift"],
        },
      }),
    findDraft: () => Promise.resolve(opts.existing ?? null),
    generate: (...args) => {
      generated++;
      return generate(...args);
    },
    saveDraft: (draft) => {
      saved.push(draft);
      return Promise.resolve("draft-" + saved.length);
    },
  });
  return { handler, saved, generated: () => generated };
}

const body = { event_id: EVENT, kind: "agenda", request_id: "req-0000001" };

Deno.test("successful agenda draft is validated, stored and returned", async () => {
  const { handler, saved } = setup(() =>
    Promise.resolve({ items: [{ title: "Intro", detail: "", start_offset_minutes: 0, duration_minutes: 60 }] })
  );
  const res = await handler(jsonRequest(URL_, body));
  assertEquals(res.status, 200);
  const json = await res.json();
  assertEquals(json.status, "succeeded");
  assertEquals(json.kind, "agenda");
  assertEquals(json.draft_id, "draft-1");
  assertEquals(json.agenda[0].starts_at, "2026-10-08T08:30:00.000Z");
  assertEquals(saved[0].status, "succeeded");
});

Deno.test("non-owners are rejected before any AI call", async () => {
  const ctx = setup(() => Promise.resolve({}), { owner: "someone-else" });
  const res = await ctx.handler(jsonRequest(URL_, body));
  assertEquals(res.status, 403);
  assertEquals((await res.json()).error, "not_owner");
  assertEquals(ctx.generated(), 0);
});

Deno.test("AI failures map to contract errors and are recorded", async () => {
  const cases: [AiError["code"], number][] = [["ai_timeout", 504], ["ai_refused", 422], ["ai_unavailable", 503]];
  for (const [code, status] of cases) {
    const { handler, saved } = setup(() => Promise.reject(new AiError(code, "x")));
    const res = await handler(jsonRequest(URL_, body));
    assertEquals(res.status, status);
    assertEquals((await res.json()).error, code);
    assertEquals(saved[0].status, "failed");
    assertEquals(saved[0].error_code, code);
  }
  const malformed = setup(() => Promise.resolve({ items: "not an array" }));
  const res = await malformed.handler(jsonRequest(URL_, body));
  assertEquals(res.status, 502);
  assertEquals((await res.json()).error, "ai_malformed");
});

Deno.test("same request_id returns the stored draft without calling the model", async () => {
  const ctx = setup(() => Promise.resolve({}), {
    existing: { id: "draft-9", kind: "questions", status: "succeeded", content: { questions: [] } },
  });
  const res = await ctx.handler(jsonRequest(URL_, { ...body, kind: "questions" }));
  assertEquals(await res.json(), { draft_id: "draft-9", kind: "questions", status: "succeeded", questions: [] });
  assertEquals(ctx.generated(), 0);
});

Deno.test("invalid input is rejected", async () => {
  const { handler } = setup(() => Promise.resolve({}));
  assertEquals((await handler(jsonRequest(URL_, { ...body, kind: "poem" }))).status, 400);
  assertEquals((await handler(jsonRequest(URL_, { ...body, request_id: "x" }))).status, 400);
  assertEquals((await handler(jsonRequest(URL_, { ...body, instructions: "x".repeat(1001) }))).status, 400);
});
