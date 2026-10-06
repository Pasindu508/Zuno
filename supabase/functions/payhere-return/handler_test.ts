import { assertEquals } from "@std/assert";
import { captureLogger } from "../_shared/test_utils.ts";
import { createReturnHandler, returnLocation } from "./handler.ts";

const ORDER = "3f2b6c1e-8a4d-4b7e-9c2f-1a2b3c4d5e6f";

Deno.test("redirects to the app deep link with the order id", () => {
  const res = createReturnHandler(captureLogger())(
    new Request(`https://x/functions/v1/payhere-return?order_id=${ORDER}`),
  );
  assertEquals(res.status, 302);
  assertEquals(res.headers.get("location"), `zuno://payments/return?order_id=${ORDER}`);
});

Deno.test("ignores invalid or injected order ids", () => {
  assertEquals(returnLocation(new URL("https://x/r?order_id=javascript:alert(1)")), "zuno://payments/return");
  assertEquals(
    returnLocation(new URL(`https://x/r?order_id=bad&order_id=${ORDER}&cancelled=1`)),
    `zuno://payments/return?order_id=${ORDER}`,
  );
});
