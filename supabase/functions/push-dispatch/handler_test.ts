import { assertEquals } from "@std/assert";
import type { PushMessage } from "../_shared/apns.ts";
import { captureLogger, jsonRequest } from "../_shared/test_utils.ts";
import { createPushHandler, type Device, parsePushBody, type Preference, preferenceFor } from "./handler.ts";

const U1 = "11111111-1111-4111-8111-111111111111";
const U2 = "22222222-2222-4222-8222-222222222222";
const U3 = "33333333-3333-4333-8333-333333333333";

function pref(user_id: string, overrides: Partial<Preference> = {}): Preference {
  return {
    user_id,
    push_enabled: true,
    event_reminders: true,
    payment_updates: true,
    event_changes: true,
    waitlist_updates: true,
    organizer_news: true,
    ...overrides,
  };
}

function setup(serviceRole = true) {
  const sent: { device: Device; message: PushMessage }[] = [];
  const removed: string[][] = [];
  const devices: Device[] = [
    { id: "d1", user_id: U1, apns_token: "aa", environment: "production" },
    { id: "d2", user_id: U2, apns_token: "bb", environment: "sandbox" },
    { id: "d3", user_id: U3, apns_token: "cc", environment: "production" },
  ];
  const handler = createPushHandler({
    log: captureLogger(),
    isServiceRole: () => serviceRole,
    loadPreferences: () =>
      Promise.resolve([pref(U1), pref(U2, { payment_updates: false }), pref(U3, { push_enabled: false })]),
    loadDevices: (ids) => Promise.resolve(devices.filter((d) => ids.includes(d.user_id))),
    send: (device, message) => {
      sent.push({ device, message });
      return Promise.resolve(
        device.id === "d1"
          ? { status: 200, unregistered: false }
          : { status: 410, reason: "Unregistered", unregistered: true },
      );
    },
    removeDevices: (ids) => {
      removed.push(ids);
      return Promise.resolve();
    },
  });
  return { handler, sent, removed };
}

Deno.test("only the service role may dispatch", async () => {
  const res = await setup(false).handler(
    jsonRequest("https://x/functions/v1/push-dispatch", { user_ids: [U1], title: "t", body: "b" }),
  );
  assertEquals(res.status, 403);
});

Deno.test("preferences filter recipients and unregistered tokens are removed", async () => {
  const { handler, sent, removed } = setup();
  const res = await handler(jsonRequest("https://x/functions/v1/push-dispatch", {
    user_ids: [U1, U2, U3],
    title: "Wallet topped up",
    body: "LKR 1,000.00 added",
    data: { kind: "payment_status" },
  }));
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { sent: 1, failed: 0, removed: 0, skipped_users: 2 });
  assertEquals(sent.map((s) => s.device.id), ["d1"]);
  assertEquals(removed, []);

  const general = await handler(
    jsonRequest("https://x/functions/v1/push-dispatch", { user_ids: [U1, U2], title: "Hi", body: "" }),
  );
  assertEquals(await general.json(), { sent: 1, failed: 1, removed: 1, skipped_users: 0 });
  assertEquals(removed, [["d2"]]);
});

Deno.test("database webhook payloads are accepted", () => {
  const parsed = parsePushBody({
    type: "INSERT",
    table: "notifications",
    record: {
      id: "n1",
      user_id: U1,
      kind: "venue_change",
      title: "Venue update",
      body: "Hall B",
      event_id: "e1",
      data: { x: 1 },
    },
  });
  assertEquals(parsed.userIds, [U1]);
  assertEquals(parsed.kind, "venue_change");
  assertEquals(parsed.message.data, { notification_id: "n1", kind: "venue_change", event_id: "e1", x: 1 });
});

Deno.test("notification kinds map to preference switches", () => {
  assertEquals(preferenceFor("refund_status"), "payment_updates");
  assertEquals(preferenceFor("schedule_change"), "event_changes");
  assertEquals(preferenceFor("waitlist_movement"), "waitlist_updates");
  assertEquals(preferenceFor("organizer_update"), "organizer_news");
  assertEquals(preferenceFor("event_reminder"), "event_reminders");
  assertEquals(preferenceFor("ticket_issued"), null);
});
