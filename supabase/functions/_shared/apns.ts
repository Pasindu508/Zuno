// APNs token-based authentication (ES256 JWT signed with WebCrypto) and send.
// Credentials: APNS_KEY_P8 (contents of the .p8 key), APNS_KEY_ID, APNS_TEAM_ID,
// APNS_TOPIC (bundle id), APNS_ENV (default environment: sandbox|production).
import { base64Decode, base64UrlEncode } from "./crypto.ts";

const encoder = new TextEncoder();

export const APNS_HOSTS = {
  production: "api.push.apple.com",
  sandbox: "api.sandbox.push.apple.com",
} as const;
export type ApnsEnvironment = keyof typeof APNS_HOSTS;

/** Imports a PKCS#8 PEM (.p8) EC P-256 private key. Accepts literal "\n". */
export function importApnsKey(p8: string): Promise<CryptoKey> {
  const pem = p8.replace(/\\n/g, "\n");
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const der = base64Decode(body);
  return crypto.subtle.importKey("pkcs8", der as BufferSource, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

/**
 * Provider authentication token: header {alg: ES256, kid}, claims {iss, iat}.
 * WebCrypto ECDSA returns the raw r||s signature (IEEE P1363), which is the
 * JWS ES256 encoding, so no DER conversion is needed.
 */
export async function createApnsJwt(key: CryptoKey, keyId: string, teamId: string, issuedAt: number): Promise<string> {
  const header = base64UrlEncode(encoder.encode(JSON.stringify({ alg: "ES256", kid: keyId })));
  const claims = base64UrlEncode(encoder.encode(JSON.stringify({ iss: teamId, iat: issuedAt })));
  const signingInput = `${header}.${claims}`;
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(signingInput));
  return `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
}

/** Caches the provider token for 50 minutes (Apple accepts 20-60 minutes). */
export class ApnsTokenCache {
  private token: string | null = null;
  private issuedAt = 0;
  constructor(
    private readonly key: CryptoKey,
    private readonly keyId: string,
    private readonly teamId: string,
  ) {}

  async get(nowSeconds = Math.floor(Date.now() / 1000)): Promise<string> {
    if (!this.token || nowSeconds - this.issuedAt > 50 * 60) {
      this.issuedAt = nowSeconds;
      this.token = await createApnsJwt(this.key, this.keyId, this.teamId, nowSeconds);
    }
    return this.token;
  }
}

export interface PushMessage {
  title: string;
  body: string;
  data?: Record<string, unknown>;
}

export function buildApnsPayload(message: PushMessage): string {
  const { aps: _ignored, ...data } = message.data ?? {};
  return JSON.stringify({
    aps: { alert: { title: message.title, body: message.body }, sound: "default" },
    ...data,
  });
}

export interface ApnsResult {
  status: number;
  reason?: string;
  /** true when the device token is permanently invalid and should be deleted */
  unregistered: boolean;
}

export async function sendApns(
  deviceToken: string,
  environment: ApnsEnvironment,
  jwt: string,
  topic: string,
  payload: string,
  fetchImpl: typeof fetch = fetch,
): Promise<ApnsResult> {
  const response = await fetchImpl(`https://${APNS_HOSTS[environment]}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": topic,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: payload,
  });
  let reason: string | undefined;
  if (response.status !== 200) {
    try {
      const body = await response.json() as { reason?: string };
      reason = body.reason;
    } catch {
      reason = undefined;
    }
  } else {
    await response.body?.cancel();
  }
  const unregistered = response.status === 410 ||
    (response.status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic"));
  return { status: response.status, reason, unregistered };
}
