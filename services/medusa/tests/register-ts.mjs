// Loaded with `node --import` before the unit tests (see test:unit).
import { register } from "node:module"

register("./resolve-ts.mjs", import.meta.url)
