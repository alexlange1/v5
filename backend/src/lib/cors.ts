/**
 * CORS handling.
 *
 * The iOS client talks to this Worker directly; CORS is mostly relevant for any
 * web/debug client. We allow the custom `X-Gist-User` identity header and the
 * two methods we actually serve.
 */

/** Base CORS headers attached to every response. */
export const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, X-Gist-User",
  "Access-Control-Max-Age": "86400",
};

/** Handle a CORS preflight (`OPTIONS`) request with a 204 + CORS headers. */
export function handlePreflight(): Response {
  return new Response(null, { status: 204, headers: { ...CORS_HEADERS } });
}

/**
 * Return a copy of `response` with CORS headers attached.
 *
 * Streaming bodies (SSE) cannot be re-read, so we preserve the original body
 * and clone only the headers + status.
 */
export function withCORS(response: Response): Response {
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(CORS_HEADERS)) {
    headers.set(key, value);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}
