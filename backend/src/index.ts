/**
 * Cloudflare Worker entry point for the Gist backend.
 *
 * Responsibilities are deliberately thin (see README): hold the model
 * credentials, inject the brevity system prompt, and enforce the daily volume
 * cap. All real work lives in the handlers; this file only wires deps and routes.
 *
 * Routing:
 *   OPTIONS *        → CORS preflight
 *   GET  /health     → handleHealth
 *   POST /v1/chat    → handleChat
 *   else             → 404 JSON
 *
 * CORS headers are attached to every response. A top-level try/catch maps any
 * unexpected throw to a generic `internal_error` 500 so we never leak stack
 * traces or upstream error bodies.
 */

import type { ChatDeps } from "./handlers/chat";
import { handleChat } from "./handlers/chat";
import { handleHealth } from "./handlers/health";
import { handlePreflight, withCORS } from "./lib/cors";
import { jsonError } from "./lib/responses";
import { KVStorage } from "./lib/storage";
import type { Env } from "./types";

export default {
  async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    // CORS preflight is handled before anything else.
    if (request.method === "OPTIONS") {
      return handlePreflight();
    }

    try {
      // Build the real dependency set. Handlers depend only on these injected
      // values, never on globals — which is what makes them unit-testable.
      const deps: ChatDeps = {
        storage: new KVStorage(env.COUNTERS),
        fetchImpl: fetch.bind(globalThis),
        now: () => new Date(),
        env,
      };

      const url = new URL(request.url);
      const { pathname } = url;

      let response: Response;
      if (request.method === "GET" && pathname === "/health") {
        response = handleHealth();
      } else if (request.method === "POST" && pathname === "/v1/chat") {
        response = await handleChat(request, deps);
      } else {
        response = jsonError("invalid_request", 404, "Not found.");
      }

      return withCORS(response);
    } catch {
      // Never leak internals. Generic, friendly 500.
      return withCORS(
        jsonError("internal_error", 500, "Something went wrong. Please retry."),
      );
    }
  },
};
