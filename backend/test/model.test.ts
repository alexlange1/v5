import { describe, it, expect } from "vitest";

import { streamModel, UpstreamError, type ModelChunk } from "../src/lib/model";
import type { ChatMessage } from "../src/types";
import {
  makeEnv,
  makeFakeFetch,
  modelErrorResponse,
  modelStreamResponse,
} from "./helpers/fakes";

const MESSAGES: ChatMessage[] = [{ role: "user", content: "Capital of France?" }];
const OPTIONS = { maxTokens: 200, temperature: 0.4, model: "z-ai/glm-4.5-air" };

/** Drain a `streamModel` generator into an array of chunks. */
async function drain(gen: AsyncGenerator<ModelChunk, void, unknown>): Promise<ModelChunk[]> {
  const out: ModelChunk[] = [];
  for await (const chunk of gen) out.push(chunk);
  return out;
}

describe("streamModel", () => {
  it("parses streamed delta chunks then a terminal done", async () => {
    const env = makeEnv();
    const fetchImpl = makeFakeFetch([
      {
        match: "/chat/completions",
        response: () => modelStreamResponse(["Paris", " is the", " capital."], "stop"),
      },
    ]);

    const chunks = await drain(streamModel({ fetchImpl, env }, MESSAGES, OPTIONS));

    expect(chunks).toEqual([
      { type: "delta", text: "Paris" },
      { type: "delta", text: " is the" },
      { type: "delta", text: " capital." },
      { type: "done", finishReason: "stop" },
    ]);
  });

  it("propagates a 'length' finish reason on the done chunk", async () => {
    const env = makeEnv();
    const fetchImpl = makeFakeFetch([
      { match: "/chat/completions", response: () => modelStreamResponse(["truncated"], "length") },
    ]);

    const chunks = await drain(streamModel({ fetchImpl, env }, MESSAGES, OPTIONS));
    const done = chunks.at(-1);
    expect(done).toEqual({ type: "done", finishReason: "length" });
  });

  it("POSTs to {MODEL_BASE_URL}/chat/completions", async () => {
    const env = makeEnv();
    const fetchImpl = makeFakeFetch([
      { match: "/chat/completions", response: () => modelStreamResponse(["ok"]) },
    ]);
    await drain(streamModel({ fetchImpl, env }, MESSAGES, OPTIONS));
    expect(fetchImpl.calls[0]).toBe(`${env.MODEL_BASE_URL}/chat/completions`);
  });

  it("throws UpstreamError on a non-ok status, before yielding any chunk", async () => {
    const env = makeEnv();
    const fetchImpl = makeFakeFetch([
      { match: "/chat/completions", response: () => modelErrorResponse(503) },
    ]);

    const gen = streamModel({ fetchImpl, env }, MESSAGES, OPTIONS);
    // The very first pull must reject (the implementation checks status before
    // yielding), and the error must be an UpstreamError carrying the status.
    await expect(gen.next()).rejects.toBeInstanceOf(UpstreamError);
  });

  it("UpstreamError carries the upstream status (for logging, not the client)", async () => {
    const env = makeEnv();
    const fetchImpl = makeFakeFetch([
      { match: "/chat/completions", response: () => modelErrorResponse(429) },
    ]);
    const gen = streamModel({ fetchImpl, env }, MESSAGES, OPTIONS);
    try {
      await gen.next();
      expect.unreachable("expected UpstreamError");
    } catch (err) {
      expect(err).toBeInstanceOf(UpstreamError);
      expect((err as UpstreamError).status).toBe(429);
    }
  });
});
