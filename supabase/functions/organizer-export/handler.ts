// organizer-export: CSV of an event's attendees for its organizer.
// Columns: reference, attendee name, tier, status, checked-in time, then one
// column per organizer question. No e-mails, phones or NIC data are exported.
import { slugify, toCsv } from "../_shared/csv.ts";

export interface ExportData {
  event_id: string;
  event_title: string;
  questions: { id: string; prompt: string; kind: string }[];
  rows: {
    reference: string;
    attendee_name: string | null;
    tier_name: string;
    status: string;
    checked_in_at: string | null;
    answers: Record<string, unknown>;
  }[];
}

export function buildExportCsv(data: ExportData, today: Date = new Date()): { filename: string; csv: string } {
  const header = [
    "Reference",
    "Attendee name",
    "Tier",
    "Status",
    "Checked-in time",
    ...data.questions.map((q) => q.prompt),
  ];
  const rows = data.rows.map((row) => [
    row.reference,
    row.attendee_name ?? "",
    row.tier_name,
    row.status,
    row.checked_in_at ?? "",
    ...data.questions.map((q) => row.answers?.[q.id] ?? ""),
  ]);
  const date = today.toISOString().slice(0, 10);
  return {
    filename: `zuno-attendees-${slugify(data.event_title)}-${date}.csv`,
    // UTF-8 BOM so spreadsheet apps render Sinhala/Tamil names correctly.
    csv: "﻿" + toCsv(header, rows),
  };
}
