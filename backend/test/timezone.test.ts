import { describe, it, expect } from "vitest";

import { localDayKey, nextLocalMidnightISO } from "../src/lib/timezone";

describe("localDayKey", () => {
  it("computes the local calendar day for a known tz + instant", () => {
    // 2026-06-28T22:30:00Z is already 2026-06-29 in Berlin (UTC+2 in summer).
    const instant = new Date("2026-06-28T22:30:00Z");
    expect(localDayKey("Europe/Berlin", instant)).toBe("2026-06-29");
    // ...but still 2026-06-28 in UTC.
    expect(localDayKey("UTC", instant)).toBe("2026-06-28");
    // ...and 2026-06-28 (afternoon) in New York (UTC-4 in summer).
    expect(localDayKey("America/New_York", instant)).toBe("2026-06-28");
  });

  it("falls back to UTC for an invalid timezone", () => {
    const instant = new Date("2026-06-28T22:30:00Z");
    expect(localDayKey("Not/AZone", instant)).toBe("2026-06-28");
  });
});

describe("nextLocalMidnightISO", () => {
  it("returns the next local midnight with the correct offset (Berlin, summer)", () => {
    const instant = new Date("2026-06-28T10:00:00Z"); // 12:00 Berlin time
    expect(nextLocalMidnightISO("Europe/Berlin", instant)).toBe("2026-06-29T00:00:00+02:00");
  });

  it("rolls over month boundaries and uses the right offset (New York)", () => {
    // 2026-06-30T23:00:00Z = 19:00 New York → next local midnight is July 1.
    const instant = new Date("2026-06-30T23:00:00Z");
    expect(nextLocalMidnightISO("America/New_York", instant)).toBe("2026-07-01T00:00:00-04:00");
  });

  it("uses Z for UTC and falls back to UTC for an invalid timezone", () => {
    const instant = new Date("2026-06-28T10:00:00Z");
    expect(nextLocalMidnightISO("UTC", instant)).toBe("2026-06-29T00:00:00Z");
    expect(nextLocalMidnightISO("Not/AZone", instant)).toBe("2026-06-29T00:00:00Z");
  });
});
