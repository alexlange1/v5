import { describe, it, expect } from "vitest";

import { getCount, refund, reserve } from "../src/lib/daily-counter";
import { InMemoryStorage } from "./helpers/fakes";

const USER = "u1";
const DAY = "2026-06-29";

describe("daily-counter", () => {
  it("getCount returns 0 when absent", async () => {
    const storage = new InMemoryStorage();
    expect(await getCount(storage, USER, DAY)).toBe(0);
  });

  it("reserve increments and returns the new count", async () => {
    const storage = new InMemoryStorage();
    expect(await reserve(storage, USER, DAY)).toBe(1);
    expect(await reserve(storage, USER, DAY)).toBe(2);
    expect(await getCount(storage, USER, DAY)).toBe(2);
  });

  it("uses the documented KV key scheme count:{userId}:{YYYY-MM-DD}", async () => {
    const storage = new InMemoryStorage();
    await reserve(storage, USER, DAY);
    expect(storage.map.get(`count:${USER}:${DAY}`)).toBe("1");
  });

  it("refund decrements, floored at 0", async () => {
    const storage = new InMemoryStorage();
    await reserve(storage, USER, DAY);
    await reserve(storage, USER, DAY);
    expect(await getCount(storage, USER, DAY)).toBe(2);

    await refund(storage, USER, DAY);
    expect(await getCount(storage, USER, DAY)).toBe(1);

    await refund(storage, USER, DAY);
    expect(await getCount(storage, USER, DAY)).toBe(0);

    // Floors at 0 — never goes negative.
    await refund(storage, USER, DAY);
    expect(await getCount(storage, USER, DAY)).toBe(0);
  });

  it("isolates counts per user and per day", async () => {
    const storage = new InMemoryStorage();
    await reserve(storage, "a", DAY);
    await reserve(storage, "a", DAY);
    await reserve(storage, "b", DAY);
    await reserve(storage, "a", "2026-06-30");

    expect(await getCount(storage, "a", DAY)).toBe(2);
    expect(await getCount(storage, "b", DAY)).toBe(1);
    expect(await getCount(storage, "a", "2026-06-30")).toBe(1);
  });
});
