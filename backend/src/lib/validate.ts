/**
 * Request validation for `POST /v1/chat`.
 *
 * This is the first step of the normative server processing order. A malformed
 * body must produce a `400 invalid_request` and never reach the model.
 *
 * Brevity and the daily cap are NOT enforced here — those are separate,
 * server-side trust boundaries. This file only validates *shape* and applies
 * the history-trimming knobs from config.
 */

import { MAX_HISTORY_MESSAGES, MAX_MESSAGE_CHARS } from "../config";
import type { ChatMessage, ChatRequest } from "../types";

/** Discriminated result so callers can map failure to a 400 message. */
export type ValidationResult =
  | { ok: true; value: ChatRequest }
  | { ok: false; message: string };

const VALID_ROLES = new Set<ChatMessage["role"]>(["user", "assistant"]);

/** Type guard for a single client-supplied message. */
function isChatMessage(value: unknown): value is ChatMessage {
  if (typeof value !== "object" || value === null) return false;
  const m = value as Record<string, unknown>;
  return (
    typeof m.role === "string" &&
    VALID_ROLES.has(m.role as ChatMessage["role"]) &&
    typeof m.content === "string"
  );
}

/**
 * Validate and normalise the request body.
 *
 * Enforces: object body; non-empty `messages`; valid roles; last turn is
 * `user`; no single message over `MAX_MESSAGE_CHARS`. Trims history to the most
 * recent `MAX_HISTORY_MESSAGES` while always preserving the latest user turn.
 */
export function validateChatRequest(body: unknown): ValidationResult {
  if (typeof body !== "object" || body === null) {
    return { ok: false, message: "Invalid request." };
  }
  const b = body as Record<string, unknown>;

  if (typeof b.userId !== "string" || b.userId.trim() === "") {
    return { ok: false, message: "Invalid request." };
  }
  if (typeof b.timezone !== "string" || b.timezone.trim() === "") {
    return { ok: false, message: "Invalid request." };
  }
  if (!Array.isArray(b.messages) || b.messages.length === 0) {
    return { ok: false, message: "Invalid request." };
  }

  // Validate every message shape and role.
  const messages: ChatMessage[] = [];
  for (const raw of b.messages) {
    if (!isChatMessage(raw)) {
      return { ok: false, message: "Invalid request." };
    }
    // Reject any single message that is absurdly long (cheap abuse guard).
    if (raw.content.length > MAX_MESSAGE_CHARS) {
      return { ok: false, message: "Message is too long." };
    }
    messages.push({ role: raw.role, content: raw.content });
  }

  // The conversation must end with a user turn (the thing being answered).
  if (messages[messages.length - 1].role !== "user") {
    return { ok: false, message: "Invalid request." };
  }

  // Trim to the most recent N turns. Slicing from the end keeps the latest user
  // turn intact (it is always the final element).
  const trimmed =
    messages.length > MAX_HISTORY_MESSAGES
      ? messages.slice(messages.length - MAX_HISTORY_MESSAGES)
      : messages;

  const value: ChatRequest = {
    userId: b.userId,
    timezone: b.timezone,
    messages: trimmed,
  };
  if (typeof b.clientVersion === "string") {
    value.clientVersion = b.clientVersion;
  }

  return { ok: true, value };
}
