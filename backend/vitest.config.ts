import { defineConfig } from "vitest/config";

/**
 * Vitest configuration.
 *
 * The backend handler + libs depend only on INJECTED deps (Storage, fetch,
 * clock) and global Web APIs (ReadableStream, TextEncoder/Decoder, Response,
 * URL) that exist in Node 22. They never touch workerd-only globals, so we run
 * under the plain `node` environment — NOT the Cloudflare workers pool. This
 * keeps `npx vitest run` fast and dependency-free (no wrangler/workerd needed).
 */
export default defineConfig({
  test: {
    environment: "node",
    globals: true,
    include: ["test/**/*.test.ts"],
  },
});
