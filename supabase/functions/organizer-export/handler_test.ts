import { assert, assertEquals } from "@std/assert";
import { buildExportCsv } from "./handler.ts";

Deno.test("export CSV has the contract columns, escaped answers and a safe filename", () => {
  const { filename, csv } = buildExportCsv({
    event_id: "e1",
    event_title: "Climate AI Hackathon",
    questions: [
      { id: "q1", prompt: "Primary skill", kind: "single_choice" },
      { id: "q2", prompt: "Need accommodation?", kind: "yes_no" },
      { id: "q3", prompt: "Team, if any", kind: "short_text" },
    ],
    rows: [
      {
        reference: "ZR-ABCDEFGH",
        attendee_name: "Perera, Nethmi",
        tier_name: "General admission",
        status: "checked_in",
        checked_in_at: "2026-10-11T03:10:00+00:00",
        answers: { q1: "Data", q2: true, q3: "=cmd()" },
      },
      {
        reference: "ZR-12345678",
        attendee_name: null,
        tier_name: "General admission",
        status: "valid",
        checked_in_at: null,
        answers: {},
      },
    ],
  }, new Date("2026-10-06T12:00:00Z"));
  assertEquals(filename, "zuno-attendees-climate-ai-hackathon-2026-10-06.csv");
  assert(csv.startsWith("﻿"));
  const lines = csv.slice(1).split("\r\n");
  assertEquals(
    lines[0],
    'Reference,Attendee name,Tier,Status,Checked-in time,Primary skill,Need accommodation?,"Team, if any"',
  );
  assertEquals(
    lines[1],
    `ZR-ABCDEFGH,"Perera, Nethmi",General admission,checked_in,2026-10-11T03:10:00+00:00,Data,Yes,'=cmd()`,
  );
  assertEquals(lines[2], "ZR-12345678,,General admission,valid,,,,");
});
