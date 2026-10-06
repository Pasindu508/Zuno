// RFC 4180 CSV with spreadsheet formula-injection protection.

/** Formats a cell value: arrays joined with "; ", booleans as Yes/No. */
export function formatCell(value: unknown): string {
  if (value === null || value === undefined) return "";
  if (typeof value === "boolean") return value ? "Yes" : "No";
  if (Array.isArray(value)) return value.map(formatCell).join("; ");
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

/**
 * Escapes one CSV field:
 * * values starting with = + - @ TAB or CR are prefixed with ' so spreadsheet
 *   apps do not evaluate attendee-controlled text as a formula;
 * * fields containing comma, quote, CR or LF (or leading/trailing spaces) are
 *   quoted and inner quotes doubled.
 */
export function csvEscape(value: unknown): string {
  let text = formatCell(value);
  if (/^[=+\-@\t\r]/.test(text)) text = "'" + text;
  if (/[",\r\n]/.test(text) || /^\s|\s$/.test(text)) {
    return '"' + text.replace(/"/g, '""') + '"';
  }
  return text;
}

export function toCsv(header: string[], rows: unknown[][]): string {
  const lines = [header, ...rows].map((row) => row.map(csvEscape).join(","));
  return lines.join("\r\n") + "\r\n";
}

export function slugify(text: string, maxLength = 40): string {
  const slug = text
    .normalize("NFKD")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, maxLength)
    .replace(/-+$/g, "");
  return slug || "event";
}
