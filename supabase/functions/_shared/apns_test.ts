import { assert, assertEquals } from "@std/assert";
import { ApnsTokenCache, buildApnsPayload, createApnsJwt, importApnsKey, sendApns } from "./apns.ts";
import { base64Decode } from "./crypto.ts";

async function generateP8(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  let binary = "";
  for (const b of pkcs8) binary += String.fromCharCode(b);
  const body = btoa(binary).match(/.{1,64}/g)!.join("\n");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`, publicKey: pair.publicKey };
}

function b64url(part: string): Uint8Array {
  const padded = part.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((part.length + 3) % 4);
  return base64Decode(padded);
}

Deno.test("APNs provider token is a valid ES256 JWT", async () => {
  const { pem, publicKey } = await generateP8();
  const key = await importApnsKey(pem.replace(/\n/g, "\\n")); // env vars often carry literal \n
  const jwt = await createApnsJwt(key, "ABC123DEFG", "TEAM123456", 1_760_000_000);
  const [header, claims, signature] = jwt.split(".");
  assertEquals(JSON.parse(new TextDecoder().decode(b64url(header))), { alg: "ES256", kid: "ABC123DEFG" });
  assertEquals(JSON.parse(new TextDecoder().decode(b64url(claims))), { iss: "TEAM123456", iat: 1_760_000_000 });
  const raw = b64url(signature);
  assertEquals(raw.length, 64, "JWS ES256 signatures are raw r||s (64 bytes)");
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    raw as BufferSource,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  assert(valid, "signature verifies with the public key");
});

Deno.test("token cache reuses the token for 50 minutes", async () => {
  const { pem } = await generateP8();
  const cache = new ApnsTokenCache(await importApnsKey(pem), "KID", "TEAM");
  const first = await cache.get(1000);
  assertEquals(await cache.get(1000 + 49 * 60), first);
  assert((await cache.get(1000 + 51 * 60)) !== first);
});

Deno.test("payload carries alert and custom data but cannot override aps", () => {
  const payload = JSON.parse(
    buildApnsPayload({ title: "Hi", body: "There", data: { event_id: "e1", aps: { badge: 99 } } }),
  );
  assertEquals(payload, { aps: { alert: { title: "Hi", body: "There" }, sound: "default" }, event_id: "e1" });
});

Deno.test("sendApns targets the right host and flags unregistered tokens", async () => {
  const calls: { url: string; headers: Headers }[] = [];
  const fake: typeof fetch = (input, init) => {
    calls.push({ url: String(input), headers: new Headers(init?.headers) });
    return Promise.resolve(Response.json({ reason: "Unregistered" }, { status: 410 }));
  };
  const result = await sendApns("abcd", "sandbox", "jwt", "lk.zuno.app", "{}", fake);
  assertEquals(calls[0].url, "https://api.sandbox.push.apple.com/3/device/abcd");
  assertEquals(calls[0].headers.get("apns-topic"), "lk.zuno.app");
  assertEquals(calls[0].headers.get("authorization"), "bearer jwt");
  assertEquals(result, { status: 410, reason: "Unregistered", unregistered: true });
});
