// Small crypto helpers built on WebCrypto and @std/crypto.
import { crypto as stdCrypto } from "@std/crypto";
import { encodeHex } from "@std/encoding/hex";

const encoder = new TextEncoder();

/** Constant-time string comparison (no early exit on the first mismatch). */
export function timingSafeEqual(a: string, b: string): boolean {
  const left = encoder.encode(a);
  const right = encoder.encode(b);
  const length = Math.max(left.length, right.length);
  let diff = left.length ^ right.length;
  for (let i = 0; i < length; i++) {
    diff |= (left[i] ?? 0) ^ (right[i] ?? 0);
  }
  return diff === 0;
}

/** MD5 (via @std/crypto, which supports non-WebCrypto digests) as lowercase hex. */
export async function md5Hex(input: string): Promise<string> {
  const digest = await stdCrypto.subtle.digest("MD5", encoder.encode(input));
  return encodeHex(new Uint8Array(digest));
}

/** HMAC-SHA-256 as lowercase hex. */
export async function hmacSha256Hex(key: Uint8Array, message: string): Promise<string> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    key as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, encoder.encode(message));
  return encodeHex(new Uint8Array(signature));
}

export function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64Decode(value: string): Uint8Array {
  const binary = atob(value);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}
