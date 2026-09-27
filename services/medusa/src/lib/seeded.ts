// Pure helpers for the seed's lookups (design D5), kept free of Medusa imports
// so they are unit-tested with node --test.

// pickSeeded chooses the record the seed should reuse. A record found by its
// recorded id wins, even when the owner renamed it; without one (never
// recorded, or deleted since) the fallback lookup by default name decides.
export async function pickSeeded<T>(
  recordedId: string | undefined,
  byId: T[],
  fallback: () => Promise<T[]>
): Promise<T | undefined> {
  if (recordedId && byId.length) {
    return byId[0]
  }
  const found = await fallback()
  return found[0]
}

// usableKeys drops revoked API keys: a revoked publishable key written out for
// the site would make every Store API call fail.
export function usableKeys<T extends { revoked_at?: unknown }>(keys: T[]): T[] {
  return keys.filter((key) => !key.revoked_at)
}
