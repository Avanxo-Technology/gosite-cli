// deleteAbandonedCarts removes every uncompleted cart last updated before the
// cutoff, in batches. Medusa's list calls paginate (15 per call by default),
// so a single call would only ever delete the first page. Returns how many
// carts were actually deleted.

export interface CartStore {
  listCarts(
    filters: Record<string, unknown>,
    config: { select: string[]; take: number }
  ): Promise<Array<{ id: string }>>
  deleteCarts(ids: string[]): Promise<unknown>
}

export async function deleteAbandonedCarts(
  store: CartStore,
  cutoff: Date,
  batchSize = 500
): Promise<number> {
  let deleted = 0
  for (;;) {
    // completed_at stays null until the cart becomes an order: orders and
    // completed carts are never selected, so they are never deleted. Each
    // round lists from the start again, because the previous batch is gone.
    const carts = await store.listCarts(
      { completed_at: { $eq: null }, updated_at: { $lt: cutoff } },
      { select: ["id"], take: batchSize }
    )
    if (!carts.length) {
      return deleted
    }
    await store.deleteCarts(carts.map((cart) => cart.id))
    deleted += carts.length
    if (carts.length < batchSize) {
      return deleted
    }
  }
}
