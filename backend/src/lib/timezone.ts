/**
 * IANA timezone helpers — the daily reset is computed in the *user's* local day,
 * not UTC, so a Berlin user resets at Berlin midnight.
 *
 * Implemented purely with `Intl.DateTimeFormat`, which is available in both
 * Workers and Node 22, so these run under plain vitest.
 *
 * An invalid/unknown timezone falls back to UTC rather than throwing.
 */

/** Returns true if the IANA tz is usable by `Intl.DateTimeFormat`. */
function isValidTimeZone(timezone: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: timezone });
    return true;
  } catch {
    return false;
  }
}

/** Resolve a usable tz, falling back to UTC for invalid input. */
function safeTimeZone(timezone: string): string {
  return isValidTimeZone(timezone) ? timezone : "UTC";
}

/**
 * The local calendar day in `timezone` as `YYYY-MM-DD`.
 *
 * Used to build the KV day-key `count:{userId}:{YYYY-MM-DD}`.
 */
export function localDayKey(timezone: string, now: Date): string {
  const tz = safeTimeZone(timezone);
  // `en-CA` formats as `YYYY-MM-DD`, which is exactly the key shape we want.
  const fmt = new Intl.DateTimeFormat("en-CA", {
    timeZone: tz,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  return fmt.format(now);
}

/**
 * Extract the wall-clock parts of `date` as seen in `timezone`.
 * Returns numbers for year/month/day/hour/minute/second.
 */
function partsInZone(
  timezone: string,
  date: Date,
): { year: number; month: number; day: number; hour: number; minute: number; second: number } {
  const fmt = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  const map: Record<string, string> = {};
  for (const part of fmt.formatToParts(date)) {
    if (part.type !== "literal") map[part.type] = part.value;
  }
  return {
    year: Number(map.year),
    month: Number(map.month),
    day: Number(map.day),
    hour: Number(map.hour),
    minute: Number(map.minute),
    second: Number(map.second),
  };
}

/** The tz offset (minutes, east-positive) in effect at `date` for `timezone`. */
function offsetMinutes(timezone: string, date: Date): number {
  const p = partsInZone(timezone, date);
  // Reconstruct the same wall-clock instant as if it were UTC, then diff.
  const asUTC = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  // Round to the second to avoid sub-second drift from `date`.
  const actual = Math.floor(date.getTime() / 1000) * 1000;
  return Math.round((asUTC - actual) / 60000);
}

/** Format a signed minute offset as an ISO-8601 suffix, e.g. `+02:00`, `Z`. */
function formatOffset(minutes: number): string {
  if (minutes === 0) return "Z";
  const sign = minutes > 0 ? "+" : "-";
  const abs = Math.abs(minutes);
  const hh = String(Math.floor(abs / 60)).padStart(2, "0");
  const mm = String(abs % 60).padStart(2, "0");
  return `${sign}${hh}:${mm}`;
}

/**
 * The next local midnight in `timezone` as ISO-8601 *with offset* — this is the
 * `resetAt` shown to the client (e.g. `2026-06-29T00:00:00+02:00`).
 *
 * Computed by taking the local Y-M-D, advancing one day, and pairing
 * `00:00:00` with the offset in effect at that midnight (handles DST shifts).
 */
export function nextLocalMidnightISO(timezone: string, now: Date): string {
  const tz = safeTimeZone(timezone);
  const today = partsInZone(tz, now);

  // Advance to the next calendar day in the local zone. Using UTC math on the
  // local Y/M/D safely rolls over month/year boundaries; we only read back the
  // resulting Y/M/D, never the time.
  const nextUTC = new Date(Date.UTC(today.year, today.month - 1, today.day + 1));
  const y = nextUTC.getUTCFullYear();
  const m = nextUTC.getUTCMonth() + 1;
  const d = nextUTC.getUTCDate();

  // The offset can differ on the reset day (DST). Probe it by constructing the
  // instant that corresponds to local midnight using the *current* offset, then
  // recomputing the offset that actually applies at that instant.
  const currentOffset = offsetMinutes(tz, now);
  const provisionalUTCms = Date.UTC(y, m - 1, d, 0, 0, 0) - currentOffset * 60000;
  const resetOffset = offsetMinutes(tz, new Date(provisionalUTCms));

  const yyyy = String(y).padStart(4, "0");
  const mm = String(m).padStart(2, "0");
  const dd = String(d).padStart(2, "0");
  return `${yyyy}-${mm}-${dd}T00:00:00${formatOffset(resetOffset)}`;
}
