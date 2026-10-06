// Test-only helpers (not imported by any function entrypoint).
import type { Logger } from "./log.ts";

export interface CapturedLogs extends Logger {
  lines: string[];
}

/** A logger that records lines instead of printing them. */
export function captureLogger(): CapturedLogs {
  const lines: string[] = [];
  const push = (level: string) => (message: string, fields?: Record<string, unknown>) => {
    lines.push(JSON.stringify({ level, message, ...(fields ?? {}) }));
  };
  return { lines, debug: push("debug"), info: push("info"), warn: push("warn"), error: push("error") };
}

export function jsonRequest(url: string, body: unknown, headers: Record<string, string> = {}): Request {
  return new Request(url, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer user-token", ...headers },
    body: JSON.stringify(body),
  });
}
