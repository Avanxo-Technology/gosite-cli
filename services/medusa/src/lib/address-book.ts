// A buyer's saved addresses filled from their orders: an account that comes
// with orders (made at checkout, or by an e-mail code that moved guest
// orders into it) would otherwise start with an empty address book while the
// addresses it shipped to sit in the orders. Pure: lib/customer-account.ts
// reads and writes them.

export const ADDRESS_FIELDS = [
  "first_name",
  "last_name",
  "company",
  "address_1",
  "address_2",
  "city",
  "province",
  "postal_code",
  "country_code",
  "phone",
] as const

export type Address = Partial<Record<(typeof ADDRESS_FIELDS)[number], string | null>>

// At most this many addresses come from orders at once.
export const MAX_SEEDED_ADDRESSES = 5

// addressKey is what makes two addresses the same place for the same person:
// case, spaces and the phone do not count.
export function addressKey(a: Address): string {
  const norm = (v: unknown) => (typeof v === "string" ? v.trim().replace(/\s+/g, " ").toLowerCase() : "")
  return ["first_name", "last_name", "address_1", "address_2", "city", "province", "country_code"]
    .map((k) => norm(a[k as keyof Address]))
    .join("|")
}

// addressesToSave are the order addresses (newest first) the book does not
// hold yet, without repeats, only those with a street and a city, and only
// the fields an address keeps.
export function addressesToSave(fromOrders: Array<Address | null | undefined>, saved: Address[]): Address[] {
  const seen = new Set(saved.map(addressKey))
  const out: Address[] = []
  for (const a of fromOrders) {
    if (!a || !a.address_1?.trim() || !a.city?.trim()) {
      continue
    }
    const key = addressKey(a)
    if (seen.has(key)) {
      continue
    }
    seen.add(key)
    const clean: Address = {}
    for (const f of ADDRESS_FIELDS) {
      const v = a[f]
      if (typeof v === "string" && v.trim() !== "") {
        clean[f] = v.trim()
      }
    }
    out.push(clean)
    if (out.length >= MAX_SEEDED_ADDRESSES) {
      break
    }
  }
  return out
}
