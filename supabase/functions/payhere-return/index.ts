import { createLogger } from "../_shared/log.ts";
import { createReturnHandler } from "./handler.ts";

Deno.serve(createReturnHandler(createLogger("payhere-return")));
