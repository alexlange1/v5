/**
 * Response builders: JSON errors and Server-Sent Events.
 *
 * All user-facing error `message`s are short, friendly strings — never stack
 * traces or upstream error bodies (see API_CONTRACT.md).
 */

import type { ErrorCode } from "../types";

/** Shared TextEncoder for writing SSE frames. */
const encoder = new TextEncoder();

/**
 * Build a JSON error response in the contract's `{ error: { code, message } }`
 * shape. `extra` merges additional fields into the error object (e.g. `tier`,
 * `limit`, `used`, `resetAt`, `retryAfter`).
 */
export function jsonError(
  code: ErrorCode,
  httpStatus: number,
  message: string,
  extra?: Record<string, unknown>,
  headers?: HeadersInit,
): Response {
  const body = JSON.stringify({ error: { code, message, ...extra } });
  const finalHeaders = new Headers(headers);
  finalHeaders.set("Content-Type", "application/json");
  return new Response(body, { status: httpStatus, headers: finalHeaders });
}

/** Build a plain JSON success response with the correct content-type. */
export function jsonResponse(
  data: unknown,
  httpStatus = 200,
  headers?: HeadersInit,
): Response {
  const finalHeaders = new Headers(headers);
  finalHeaders.set("Content-Type", "application/json");
  return new Response(JSON.stringify(data), { status: httpStatus, headers: finalHeaders });
}

/**
 * Encode one SSE frame: a named event with single-line JSON data.
 *
 * Shape (per contract):
 *   event: <name>\n
 *   data: <json>\n
 *   \n
 */
export function encodeSSEEvent(event: string, data: unknown): Uint8Array {
  // JSON.stringify never emits raw newlines, so the payload stays single-line.
  const frame = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  return encoder.encode(frame);
}

/**
 * Wrap a `ReadableStream` of bytes as a streaming SSE `Response` with the
 * required headers. Caller is responsible for enqueuing `encodeSSEEvent(...)`
 * frames and closing the stream.
 */
export function sseResponse(stream: ReadableStream<Uint8Array>, headers?: HeadersInit): Response {
  const finalHeaders = new Headers(headers);
  finalHeaders.set("Content-Type", "text/event-stream");
  finalHeaders.set("Cache-Control", "no-cache");
  finalHeaders.set("Connection", "keep-alive");
  return new Response(stream, { status: 200, headers: finalHeaders });
}
