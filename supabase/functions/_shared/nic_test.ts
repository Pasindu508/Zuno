// HMAC vectors computed independently with Python:
//   hmac.new(b"zuno-test-hmac-key-0123456789-abcdef", b"198512304567", hashlib.sha256).hexdigest()
import { assertEquals, assertThrows } from "@std/assert";
import { canonicalizeNic, decodeHmacKey, nicDigest } from "./nic.ts";

const NOW = new Date("2026-10-06T00:00:00Z");
const KEY = new TextEncoder().encode("zuno-test-hmac-key-0123456789-abcdef"); // test key only

Deno.test("12-digit NICs are accepted as-is", () => {
  assertEquals(canonicalizeNic("200012345678", NOW), "200012345678");
  assertEquals(canonicalizeNic(" 1985 123 04567 ", NOW), "198512304567");
});

Deno.test("old 9-digit + V/X NICs are canonicalised to 12 digits", () => {
  // 19 + d[0..5] + 0 + d[5..9]
  assertEquals(canonicalizeNic("851234567V", NOW), "198512304567");
  assertEquals(canonicalizeNic("851234567v", NOW), "198512304567");
  assertEquals(canonicalizeNic("856234567X", NOW), "198562304567"); // day 623 (female)
});

Deno.test("old and new spellings of the same NIC canonicalise identically", () => {
  assertEquals(canonicalizeNic("851234567V", NOW), canonicalizeNic("198512304567", NOW));
});

Deno.test("invalid formats are rejected", () => {
  for (
    const value of [
      "",
      "12345",
      "85123456V",
      "8512345678V",
      "851234567Z",
      "ABCDEFGHIJKL",
      "20001234567",
      "2000123456789",
    ]
  ) {
    assertEquals(canonicalizeNic(value, NOW), null, value);
  }
  assertEquals(canonicalizeNic(851234567, NOW), null);
  assertEquals(canonicalizeNic(null, NOW), null);
});

Deno.test("impossible day-of-year or year values are rejected", () => {
  assertEquals(canonicalizeNic("200000012345", NOW), null); // day 000
  assertEquals(canonicalizeNic("200040012345", NOW), null); // day 400
  assertEquals(canonicalizeNic("200090012345", NOW), null); // day 900
  assertEquals(canonicalizeNic("203012312345", NOW), null); // future year
  assertEquals(canonicalizeNic("185012312345", NOW), null); // before 1900
});

Deno.test("HMAC-SHA-256 digest matches the independently computed vector", async () => {
  assertEquals(
    await nicDigest("198512304567", KEY),
    "2e02accab7df632f2c38e5dcbb7dfafa75fda398ddfa3ea582d9f606c68a1e55",
  );
  assertEquals(
    await nicDigest("200012345678", KEY),
    "1ef5db7ae0d4eb076faf9254910a20e1b884a5a6f231ce7ef0cf215b9c3a6ed2",
  );
});

Deno.test("decodeHmacKey supports raw, base64 and hex keys and enforces 32 bytes", () => {
  assertEquals(decodeHmacKey("zuno-test-hmac-key-0123456789-abcdef").length, 36);
  assertEquals(decodeHmacKey("base64:" + btoa("x".repeat(32))).length, 32);
  assertEquals(decodeHmacKey("hex:" + "ab".repeat(32)).length, 32);
  assertThrows(() => decodeHmacKey("too-short"));
  assertThrows(() => decodeHmacKey("hex:zz"));
});
