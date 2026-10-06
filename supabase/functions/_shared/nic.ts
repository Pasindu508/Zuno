// Sri Lankan NIC validation, canonicalisation and keyed digest.
//
// Formats:
//   new: 12 digits  YYYY DDD S SSS C   (year, day-of-year [+500 for women], serial, check)
//   old: 9 digits + V/X   YY DDD SSS C + V|X
// Old numbers are canonicalised to the 12-digit form before hashing so both
// spellings of the same person produce the same digest:
//   canonical = "19" + d[0..5] + "0" + d[5..9]
// The raw NIC is never stored or logged; only HMAC-SHA-256(NIC_HMAC_KEY, canonical).
import { base64Decode, hmacSha256Hex } from "./crypto.ts";

export function canonicalizeNic(raw: unknown, now: Date = new Date()): string | null {
  if (typeof raw !== "string") return null;
  const value = raw.trim().toUpperCase().replace(/[\s-]/g, "");
  let canonical: string;
  if (/^\d{12}$/.test(value)) {
    canonical = value;
  } else if (/^\d{9}[VX]$/.test(value)) {
    const digits = value.slice(0, 9);
    canonical = "19" + digits.slice(0, 5) + "0" + digits.slice(5, 9);
  } else {
    return null;
  }

  const year = Number(canonical.slice(0, 4));
  const day = Number(canonical.slice(4, 7));
  if (year < 1900 || year > now.getUTCFullYear()) return null;
  // Day of year: 1-366 (male) or 501-866 (female).
  if (!((day >= 1 && day <= 366) || (day >= 501 && day <= 866))) return null;
  return canonical;
}

/**
 * Decodes NIC_HMAC_KEY. Accepts "base64:<...>", "hex:<...>" or a raw string.
 * Requires at least 32 bytes of key material.
 */
export function decodeHmacKey(secret: string): Uint8Array {
  let bytes: Uint8Array;
  if (secret.startsWith("base64:")) {
    bytes = base64Decode(secret.slice(7));
  } else if (secret.startsWith("hex:")) {
    const hex = secret.slice(4);
    if (!/^([0-9a-fA-F]{2})+$/.test(hex)) throw new Error("NIC_HMAC_KEY hex is malformed");
    bytes = new Uint8Array(hex.match(/../g)!.map((pair) => parseInt(pair, 16)));
  } else {
    bytes = new TextEncoder().encode(secret);
  }
  if (bytes.length < 32) throw new Error("NIC_HMAC_KEY must contain at least 32 bytes");
  return bytes;
}

export function nicDigest(canonical: string, key: Uint8Array): Promise<string> {
  return hmacSha256Hex(key, canonical);
}
