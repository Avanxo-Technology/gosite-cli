// Resolve hook for the unit tests. Medusa's sources import sibling modules
// without an extension ("./wompi"), which Node's ESM resolver rejects. When a
// relative specifier is not found, this retries it with a .ts extension.
export async function resolve(specifier, context, nextResolve) {
  try {
    return await nextResolve(specifier, context)
  } catch (error) {
    if (error.code !== "ERR_MODULE_NOT_FOUND" || !specifier.startsWith(".") || !context.parentURL) {
      throw error
    }
    return nextResolve(`${specifier}.ts`, context)
  }
}
