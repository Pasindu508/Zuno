// Structured JSON logging that never writes secrets or personal data.
//
// Rules (see docs/backend/SECURITY_BACKEND.md):
// * never log access tokens, API keys, NICs or their digests, card data,
//   registration answers, phone numbers or e-mail addresses;
// * any field whose key looks sensitive is replaced with "[redacted]",
//   recursively, before the line is written.

const SENSITIVE_KEY =
  /(authorization|token|secret|password|passwd|nic|digest|card|md5sig|hash|answers?|phone|email|apikey|api_key|private|p8|cookie|signature)/i;

const MAX_DEPTH = 5;

export function redact(value: unknown, depth = 0): unknown {
  if (depth > MAX_DEPTH) return "[truncated]";
  if (Array.isArray(value)) return value.map((item) => redact(item, depth + 1));
  if (value instanceof Error) return { name: value.name, message: value.message };
  if (value !== null && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, inner] of Object.entries(value as Record<string, unknown>)) {
      out[key] = SENSITIVE_KEY.test(key) ? "[redacted]" : redact(inner, depth + 1);
    }
    return out;
  }
  if (typeof value === "string" && value.length > 500) return value.slice(0, 500) + "...";
  return value;
}

export type LogLevel = "debug" | "info" | "warn" | "error";

export interface Logger {
  debug(message: string, fields?: Record<string, unknown>): void;
  info(message: string, fields?: Record<string, unknown>): void;
  warn(message: string, fields?: Record<string, unknown>): void;
  error(message: string, fields?: Record<string, unknown>): void;
}

export function formatLogLine(
  level: LogLevel,
  fn: string,
  message: string,
  fields: Record<string, unknown> = {},
): string {
  return JSON.stringify({
    ts: new Date().toISOString(),
    level,
    fn,
    message,
    ...(redact(fields) as Record<string, unknown>),
  });
}

export function createLogger(fn: string): Logger {
  const write = (level: LogLevel, message: string, fields?: Record<string, unknown>) => {
    const line = formatLogLine(level, fn, message, fields ?? {});
    if (level === "error") console.error(line);
    else if (level === "warn") console.warn(line);
    else console.log(line);
  };
  return {
    debug: (m, f) => write("debug", m, f),
    info: (m, f) => write("info", m, f),
    warn: (m, f) => write("warn", m, f),
    error: (m, f) => write("error", m, f),
  };
}
