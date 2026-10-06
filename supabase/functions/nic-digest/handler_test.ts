import { assertEquals } from "@std/assert";
import { HttpError } from "../_shared/http.ts";
import { captureLogger, jsonRequest } from "../_shared/test_utils.ts";
import { createNicDigestHandler } from "./handler.ts";

const KEY = new TextEncoder().encode("zuno-test-hmac-key-0123456789-abcdef"); // test key only

function setup(
  opts: { rateLimited?: boolean; unauthenticated?: boolean; status?: "verified_unique" | "duplicate" } = {},
) {
  const digests: { userId: string; digest: string; version: number }[] = [];
  const log = captureLogger();
  const handler = createNicDigestHandler({
    log,
    authenticate: () =>
      opts.unauthenticated ? Promise.reject(new HttpError(401, "not_authenticated")) : Promise.resolve("user-1"),
    rateLimit: () => (opts.rateLimited ? Promise.reject(new HttpError(429, "rate_limited")) : Promise.resolve()),
    hmacKey: () => ({ key: KEY, version: 2 }),
    recordDigest: (userId, digest, version) => {
      digests.push({ userId, digest, version });
      return Promise.resolve({ status: opts.status ?? "verified_unique" });
    },
  });
  return { handler, digests, log };
}

const URL_ = "https://x/functions/v1/nic-digest";

Deno.test("valid new-format NIC stores only the HMAC digest", async () => {
  const { handler, digests, log } = setup();
  const res = await handler(jsonRequest(URL_, { nic: "198512304567" }));
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { status: "verified_unique" });
  assertEquals(digests, [{
    userId: "user-1",
    digest: "2e02accab7df632f2c38e5dcbb7dfafa75fda398ddfa3ea582d9f606c68a1e55",
    version: 2,
  }]);
  assertEquals(
    log.lines.some((l) => l.includes("198512304567") || l.includes("2e02acca")),
    false,
    "NIC/digest never logged",
  );
});

Deno.test("old-format NIC produces the same digest as its 12-digit form", async () => {
  const { handler, digests } = setup();
  await handler(jsonRequest(URL_, { nic: "851234567v" }));
  assertEquals(digests[0].digest, "2e02accab7df632f2c38e5dcbb7dfafa75fda398ddfa3ea582d9f606c68a1e55");
});

Deno.test("duplicate status is passed through", async () => {
  const { handler } = setup({ status: "duplicate" });
  assertEquals(await (await handler(jsonRequest(URL_, { nic: "200012345678" }))).json(), { status: "duplicate" });
});

Deno.test("invalid format, rate limit and missing auth map to contract errors", async () => {
  const bad = await setup().handler(jsonRequest(URL_, { nic: "12345" }));
  assertEquals(bad.status, 400);
  assertEquals((await bad.json()).error, "invalid_format");
  const limited = await setup({ rateLimited: true }).handler(jsonRequest(URL_, { nic: "200012345678" }));
  assertEquals(limited.status, 429);
  assertEquals((await limited.json()).error, "rate_limited");
  const anon = await setup({ unauthenticated: true }).handler(jsonRequest(URL_, { nic: "200012345678" }));
  assertEquals(anon.status, 401);
});
