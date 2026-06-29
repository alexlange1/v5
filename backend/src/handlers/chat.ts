/**
 * `POST /v1/chat` handler — the core orchestration.
 *
 * Implements EXACTLY the normative "Server processing order" from
 * API_CONTRACT.md:
 *
 *   1. validate (400)
 *   2. per-minute rate limit (429 + Retry-After)
 *   3. resolve entitlement (fail-closed to free)
 *   4. local day key + read count
 *   5. cap check (free: FREE_DAILY_MESSAGE_LIMIT, paid: PAID_DAILY_SOFT_CAP)
 *      → over: 402 daily_limit_reached, model NOT called
 *   6. circuit breaker (free only) → 503 circuit_open
 *   7. reserve (increment count + add estimated spend)
 *   8. prepend SYSTEM_PROMPT, call the streaming model
 *   9. stream: meta first, then deltas, then done.
 *      pre-stream upstream failure → refund + 502
 *      mid-stream failure → emit SSE `error`, keep count consumed
 *
 * The handler is PURE with respect to injected deps: it never touches global KV,
 * `Date`, or `fetch` directly. This is what makes it unit-testable under plain
 * vitest.
 */

import {
  EST_COST_PER_REQUEST_EUR,
  FREE_DAILY_MESSAGE_LIMIT,
  MAX_OUTPUT_TOKENS,
  MODEL_NAME,
  MODEL_TEMPERATURE,
  PAID_DAILY_SOFT_CAP,
  SYSTEM_PROMPT,
} from "../config";
import type {
  ChatMessage,
  DeltaEvent,
  DoneEvent,
  Env,
  ErrorEvent,
  MetaEvent,
  Tier,
} from "../types";
import { addSpend, isOpen } from "../lib/circuit-breaker";
import { getCount, refund, reserve } from "../lib/daily-counter";
import { resolveTier } from "../lib/entitlement";
import { streamModel, UpstreamError } from "../lib/model";
import { checkRateLimit } from "../lib/rate-limit";
import { encodeSSEEvent, jsonError, sseResponse } from "../lib/responses";
import type { Storage } from "../lib/storage";
import { localDayKey, nextLocalMidnightISO } from "../lib/timezone";
import { validateChatRequest } from "../lib/validate";

/** Injected dependencies — no globals, so the handler is fully testable. */
export interface ChatDeps {
  storage: Storage;
  fetchImpl: typeof fetch;
  /** Clock injection: returns "now". */
  now: () => Date;
  env: Env;
}

/** The active daily cap for a tier. */
function capForTier(tier: Tier): number {
  return tier === "paid" ? PAID_DAILY_SOFT_CAP : FREE_DAILY_MESSAGE_LIMIT;
}

export async function handleChat(request: Request, deps: ChatDeps): Promise<Response> {
  const { storage, fetchImpl, now, env } = deps;

  // --- Step 1: validate -----------------------------------------------------
  let rawBody: unknown;
  try {
    rawBody = await request.json();
  } catch {
    return jsonError("invalid_request", 400, "Invalid request.");
  }

  const validation = validateChatRequest(rawBody);
  if (!validation.ok) {
    return jsonError("invalid_request", 400, validation.message);
  }
  const { userId, timezone, messages } = validation.value;

  // The `X-Gist-User` header is the authoritative identity per the contract; when
  // present it must match the body `userId`. (Identity is anonymous/self-asserted,
  // so this is a contract-consistency check, not a security boundary.)
  const headerUser = request.headers.get("X-Gist-User");
  if (headerUser && headerUser !== userId) {
    return jsonError("invalid_request", 400, "Invalid request.");
  }

  // --- Step 2: per-minute rate limit ---------------------------------------
  const nowDate = now();
  const rl = await checkRateLimit(storage, userId, nowDate);
  if (!rl.allowed) {
    const retryAfter = rl.retryAfter ?? 60;
    return jsonError(
      "rate_limited",
      429,
      "Slow down a moment.",
      { retryAfter },
      { "Retry-After": String(retryAfter) },
    );
  }

  // --- Step 3: resolve entitlement (fail-closed to free) -------------------
  const tier = await resolveTier({ storage, fetchImpl, env }, userId);

  // --- Step 4: local day key + read current count --------------------------
  // Per-user counting resets at the user's *local* midnight, so the count key is
  // keyed by their local day. The global spend backstop, by contrast, must be a
  // single bucket shared by all users regardless of timezone — otherwise the
  // ceiling would be fragmented across ~24 timezone-day buckets and never trip.
  // It therefore uses a fixed UTC calendar day (see docs/CONFIG.md `spend:` key).
  const dayKey = localDayKey(timezone, nowDate);
  const spendDayKey = localDayKey("UTC", nowDate);
  const resetAt = nextLocalMidnightISO(timezone, nowDate);
  const currentCount = await getCount(storage, userId, dayKey);

  // --- Step 5: cap check (model NOT called when over) -----------------------
  const limit = capForTier(tier);
  if (currentCount >= limit) {
    return jsonError("daily_limit_reached", 402, "You've used all your free messages for today.", {
      tier,
      limit,
      used: currentCount,
      resetAt,
    });
  }

  // --- Step 6: circuit breaker (free traffic only) -------------------------
  if (tier === "free" && (await isOpen(storage, spendDayKey))) {
    return jsonError("circuit_open", 503, "We're at capacity right now. Try again shortly.");
  }

  // --- Step 7: reserve (increment count + add spend estimate) --------------
  const used = await reserve(storage, userId, dayKey);
  await addSpend(storage, spendDayKey, EST_COST_PER_REQUEST_EUR);
  const remaining = Math.max(0, limit - used);

  // --- Step 8: prepend the system prompt -----------------------------------
  const modelMessages: ChatMessage[] = [
    // SYSTEM_PROMPT is injected server-side on every call; the `system` role is
    // intentionally outside ChatMessage's client-facing role union, so cast.
    { role: "system", content: SYSTEM_PROMPT } as unknown as ChatMessage,
    ...messages,
  ];

  // --- Step 8/9: open the stream. A pre-stream upstream failure must refund
  // and return a normal 502 *before* we commit to a 200 SSE response. We obtain
  // the generator and pull its first chunk here so the throw happens early.
  const generator = streamModel({ fetchImpl, env }, modelMessages, {
    maxTokens: MAX_OUTPUT_TOKENS,
    temperature: MODEL_TEMPERATURE,
    model: MODEL_NAME,
  });

  let firstChunk: IteratorResult<{ type: string }, void>;
  try {
    firstChunk = (await generator.next()) as IteratorResult<{ type: string }, void>;
  } catch (err) {
    // Pre-stream failure: nothing was produced → refund and return 502 JSON.
    if (err instanceof UpstreamError) {
      await refund(storage, userId, dayKey);
      return jsonError("upstream_error", 502, "The model is unavailable. Please retry.");
    }
    // Any other unexpected pre-stream error: refund and surface a generic 502.
    await refund(storage, userId, dayKey);
    return jsonError("upstream_error", 502, "The model is unavailable. Please retry.");
  }

  // --- Step 9: success → 200 text/event-stream -----------------------------
  const meta: MetaEvent = { tier, used, limit, remaining, resetAt };

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      try {
        // `meta` is emitted FIRST, before any token.
        controller.enqueue(encodeSSEEvent("meta", meta));

        let finishReason: DoneEvent["finishReason"] = "stop";

        // Drain the generator, starting from the chunk we already pulled.
        let result = firstChunk;
        while (!result.done) {
          const chunk = result.value as
            | { type: "delta"; text: string }
            | { type: "done"; finishReason: DoneEvent["finishReason"] };

          if (chunk.type === "delta") {
            const delta: DeltaEvent = { text: chunk.text };
            controller.enqueue(encodeSSEEvent("delta", delta));
          } else if (chunk.type === "done") {
            finishReason = chunk.finishReason;
          }
          result = (await generator.next()) as IteratorResult<{ type: string }, void>;
        }

        const done: DoneEvent = { finishReason, used, remaining };
        controller.enqueue(encodeSSEEvent("done", done));
        controller.close();
      } catch {
        // Mid-stream failure: at least one token may have been sent. Per the
        // contract, emit an SSE `error` event and KEEP the count consumed.
        const errorEvent: ErrorEvent = {
          code: "upstream_error",
          message: "The model is unavailable. Please retry.",
        };
        controller.enqueue(encodeSSEEvent("error", errorEvent));
        controller.close();
      }
    },
  });

  return sseResponse(stream);
}
