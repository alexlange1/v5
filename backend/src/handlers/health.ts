/**
 * `GET /health` handler — a liveness probe with the app version.
 */

import { APP_VERSION } from "../config";
import { jsonResponse } from "../lib/responses";

export function handleHealth(): Response {
  return jsonResponse({ status: "ok", version: APP_VERSION });
}
