import { assert, assertEquals } from "@std/assert";
import { dbError } from "./http.ts";
import { formatLogLine, redact } from "./log.ts";
import { timingSafeEqual } from "./crypto.ts";

Deno.test("sensitive fields are redacted recursively", () => {
  const out = redact({
    user_id: "u1",
    nic: "200012345678",
    authorization: "Bearer abc",
    nested: { access_token: "t", answers: [{ value: "secret" }], order_id: "o1" },
    card_no: "4111",
  }) as Record<string, unknown>;
  assertEquals(out.user_id, "u1");
  assertEquals(out.nic, "[redacted]");
  assertEquals(out.authorization, "[redacted]");
  assertEquals(out.card_no, "[redacted]");
  assertEquals((out.nested as Record<string, unknown>).access_token, "[redacted]");
  assertEquals((out.nested as Record<string, unknown>).answers, "[redacted]");
  assertEquals((out.nested as Record<string, unknown>).order_id, "o1");
});

Deno.test("log lines are JSON and never contain redacted values", () => {
  const line = formatLogLine("info", "nic-digest", "done", { nic: "200012345678", digest: "abc", status: "ok" });
  assert(!line.includes("200012345678") && !line.includes("abc"));
  assertEquals(JSON.parse(line).status, "ok");
});

Deno.test("database errors map to contract codes without leaking internals", () => {
  const sold = dbError({ code: "P0001", message: "sold_out" });
  assertEquals([sold.status, sold.code], [409, "sold_out"]);
  const limited = dbError({ code: "P0001", message: "rate_limited" });
  assertEquals([limited.status, limited.code], [429, "rate_limited"]);
  const internal = dbError({ code: "42P01", message: 'relation "x" does not exist' });
  assertEquals([internal.status, internal.code], [500, "internal_error"]);
  assert(!internal.message.includes("relation"));
});

Deno.test("timingSafeEqual compares full strings", () => {
  assert(timingSafeEqual("ABC", "ABC"));
  assert(!timingSafeEqual("ABC", "ABD"));
  assert(!timingSafeEqual("ABC", "ABCD"));
  assert(!timingSafeEqual("", "A"));
});
