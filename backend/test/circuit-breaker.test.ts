import { describe, it, expect } from "vitest";

import { addSpend, isOpen } from "../src/lib/circuit-breaker";
import { DAILY_SPEND_CEILING_EUR, EST_COST_PER_REQUEST_EUR } from "../src/config";
import { InMemoryStorage } from "./helpers/fakes";

const DAY = "2026-06-29";

describe("circuit-breaker", () => {
  it("is closed when there is no recorded spend", async () => {
    const storage = new InMemoryStorage();
    expect(await isOpen(storage, DAY)).toBe(false);
  });

  it("stays closed below the ceiling and opens at/above it", async () => {
    const storage = new InMemoryStorage();

    // Just under the ceiling.
    await addSpend(storage, DAY, DAILY_SPEND_CEILING_EUR - EST_COST_PER_REQUEST_EUR);
    expect(await isOpen(storage, DAY)).toBe(false);

    // One more request pushes it to exactly the ceiling → open.
    await addSpend(storage, DAY, EST_COST_PER_REQUEST_EUR);
    expect(await isOpen(storage, DAY)).toBe(true);
  });

  it("opens once spend exceeds the ceiling", async () => {
    const storage = new InMemoryStorage();
    await addSpend(storage, DAY, DAILY_SPEND_CEILING_EUR + 1);
    expect(await isOpen(storage, DAY)).toBe(true);
  });

  it("uses the documented KV key scheme spend:{YYYY-MM-DD} and accumulates", async () => {
    const storage = new InMemoryStorage();
    await addSpend(storage, DAY, 0.0008);
    await addSpend(storage, DAY, 0.0008);
    expect(storage.map.get(`spend:${DAY}`)).toBe("0.0016");
  });

  it("isolates spend per day", async () => {
    const storage = new InMemoryStorage();
    await addSpend(storage, DAY, DAILY_SPEND_CEILING_EUR);
    expect(await isOpen(storage, DAY)).toBe(true);
    // A different day starts fresh.
    expect(await isOpen(storage, "2026-06-30")).toBe(false);
  });
});
