/**
 * OpenAI-compatible streaming model client.
 *
 * POSTs to `{MODEL_BASE_URL}/chat/completions` with `stream: true` and yields
 * decoded delta chunks, then a terminal `done` with the finish reason.
 *
 * The CALLER prepends the system prompt — this client streams whatever messages
 * it is given verbatim.
 *
 * If the upstream response status is NOT ok, an `UpstreamError` is thrown
 * BEFORE any chunk is yielded, so the handler can refund + return a 502 cleanly.
 *
 * `fetch` is injected for testability under plain vitest.
 */

import type { ChatMessage, Env } from "../types";

/** Thrown when the upstream returns a non-2xx BEFORE any token is produced. */
export class UpstreamError extends Error {
  constructor(
    message: string,
    /** Upstream HTTP status, for logging (never surfaced to the client). */
    public readonly status: number,
  ) {
    super(message);
    this.name = "UpstreamError";
  }
}

/** A streamed text chunk. */
export interface ModelDeltaChunk {
  type: "delta";
  text: string;
}

/** The terminal chunk. `finishReason` mirrors the contract's `done` event. */
export interface ModelDoneChunk {
  type: "done";
  finishReason: "stop" | "length";
}

/** Discriminated union yielded by `streamModel`. */
export type ModelChunk = ModelDeltaChunk | ModelDoneChunk;

/** Dependencies for the model client (injected for testability). */
export interface ModelDeps {
  fetchImpl: typeof fetch;
  env: Env;
}

/** Per-call generation options. */
export interface StreamModelOptions {
  maxTokens: number;
  temperature: number;
  model: string;
}

/** Shape of a single OpenAI-compatible streaming chunk we care about. */
interface UpstreamStreamChunk {
  choices?: Array<{
    delta?: { content?: string | null };
    finish_reason?: string | null;
  }>;
}

/** Map an upstream finish_reason onto the contract's allowed values. */
function normalizeFinishReason(reason: string | null | undefined): "stop" | "length" {
  return reason === "length" ? "length" : "stop";
}

/**
 * Stream a completion. Yields `{type:"delta"}` chunks as text arrives, then a
 * final `{type:"done"}`.
 *
 * @throws UpstreamError if the upstream status is not ok (before yielding).
 */
export async function* streamModel(
  deps: ModelDeps,
  messages: ChatMessage[],
  options: StreamModelOptions,
): AsyncGenerator<ModelChunk, void, unknown> {
  const { fetchImpl, env } = deps;

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${env.MODEL_API_KEY}`,
  };
  // Optional OpenRouter attribution headers.
  if (env.MODEL_HTTP_REFERER) {
    headers["HTTP-Referer"] = env.MODEL_HTTP_REFERER;
    headers["X-Title"] = "Gist";
  }

  const body = JSON.stringify({
    model: options.model,
    messages,
    max_tokens: options.maxTokens,
    temperature: options.temperature,
    stream: true,
  });

  const res = await fetchImpl(`${env.MODEL_BASE_URL}/chat/completions`, {
    method: "POST",
    headers,
    body,
  });

  // Fail BEFORE yielding anything so the handler can refund + 502.
  if (!res.ok || !res.body) {
    throw new UpstreamError(`Upstream returned ${res.status}`, res.status);
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let finishReason: "stop" | "length" = "stop";

  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });

      // SSE frames are separated by blank lines; process complete lines.
      let newlineIndex: number;
      while ((newlineIndex = buffer.indexOf("\n")) !== -1) {
        const line = buffer.slice(0, newlineIndex).trim();
        buffer = buffer.slice(newlineIndex + 1);

        if (line === "" || !line.startsWith("data:")) continue;

        const data = line.slice("data:".length).trim();
        if (data === "[DONE]") {
          yield { type: "done", finishReason };
          return;
        }

        let parsed: UpstreamStreamChunk;
        try {
          parsed = JSON.parse(data) as UpstreamStreamChunk;
        } catch {
          // Ignore unparsable keep-alive / comment lines.
          continue;
        }

        const choice = parsed.choices?.[0];
        const text = choice?.delta?.content;
        if (typeof text === "string" && text.length > 0) {
          yield { type: "delta", text };
        }
        if (choice?.finish_reason) {
          finishReason = normalizeFinishReason(choice.finish_reason);
        }
      }
    }
  } finally {
    reader.releaseLock();
  }

  // Upstream closed without an explicit [DONE]; still emit a terminal done.
  yield { type: "done", finishReason };
}
