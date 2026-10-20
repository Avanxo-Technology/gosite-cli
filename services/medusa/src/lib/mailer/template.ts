// A small subset of Go's html/template, so a store's e-mails read like the
// gosite site templates they sit next to. Kept free of Medusa imports so it is
// unit-tested with node --test.
//
//   {{ .order.display_id }}    a value, HTML-escaped; "." is the current scope
//   {{ $.store.name }}         "$" is the root scope, also inside range
//   {{ raw .order.metadata.note }}   a value written as is (trusted HTML)
//   {{ if .order.shipping_address }} ... {{ else }} ... {{ end }}
//   {{ range .order.items }} {{ .title }} {{ else }} none {{ end }}
//   {{/* a comment */}}
//
// A missing value renders as nothing, as in Go with missingkey=zero, so a
// template written for one event never fails on another event's data.

export class TemplateError extends Error {}

type Node =
  | { kind: "text"; text: string }
  | { kind: "value"; path: string; raw: boolean }
  | { kind: "if"; path: string; then: Node[]; else: Node[] }
  | { kind: "range"; path: string; body: Node[]; else: Node[] }

type Token = { kind: "text"; text: string } | { kind: "action"; action: string; at: number }

function tokenize(source: string): Token[] {
  const tokens: Token[] = []
  let i = 0
  while (i < source.length) {
    const open = source.indexOf("{{", i)
    if (open === -1) {
      tokens.push({ kind: "text", text: source.slice(i) })
      break
    }
    if (open > i) {
      tokens.push({ kind: "text", text: source.slice(i, open) })
    }
    const close = source.indexOf("}}", open + 2)
    if (close === -1) {
      throw new TemplateError(`unclosed action at character ${open}`)
    }
    tokens.push({ kind: "action", action: source.slice(open + 2, close).trim(), at: open })
    i = close + 2
  }
  return tokens
}

const PATH = /^(\$|\.)([A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*)?$|^\$\.([A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*)$/

function checkPath(path: string, at: number): string {
  if (!PATH.test(path)) {
    throw new TemplateError(`"${path}" at character ${at} is not a value: write .name, .a.b, . or $.name`)
  }
  return path
}

// parse turns the tokens into a tree. stop lists the actions that end the
// current block ("else", "end"); the one found is returned with the nodes.
function parse(tokens: Token[], pos: { i: number }, stop: string[]): { nodes: Node[]; ended?: string } {
  const nodes: Node[] = []
  while (pos.i < tokens.length) {
    const token = tokens[pos.i++]
    if (token.kind === "text") {
      nodes.push(token)
      continue
    }
    const { action, at } = token
    if (action.startsWith("/*")) {
      if (!action.endsWith("*/")) {
        throw new TemplateError(`unclosed comment at character ${at}`)
      }
      continue
    }
    if (stop.includes(action)) {
      return { nodes, ended: action }
    }
    const [word, ...rest] = action.split(/\s+/)
    const arg = rest.join(" ")
    if (word === "if" || word === "range") {
      const path = checkPath(arg, at)
      const first = parse(tokens, pos, ["else", "end"])
      let otherwise: Node[] = []
      if (first.ended === "else") {
        const second = parse(tokens, pos, ["end"])
        if (second.ended !== "end") {
          throw new TemplateError(`{{ ${word} }} at character ${at} has no {{ end }}`)
        }
        otherwise = second.nodes
      } else if (first.ended !== "end") {
        throw new TemplateError(`{{ ${word} }} at character ${at} has no {{ end }}`)
      }
      nodes.push(
        word === "if"
          ? { kind: "if", path, then: first.nodes, else: otherwise }
          : { kind: "range", path, body: first.nodes, else: otherwise }
      )
      continue
    }
    if (word === "else" || word === "end") {
      throw new TemplateError(`{{ ${word} }} at character ${at} has no {{ if }} or {{ range }}`)
    }
    if (word === "raw") {
      nodes.push({ kind: "value", path: checkPath(arg, at), raw: true })
      continue
    }
    nodes.push({ kind: "value", path: checkPath(action, at), raw: false })
  }
  return { nodes }
}

function compile(source: string): Node[] {
  const pos = { i: 0 }
  const tokens = tokenize(source)
  const { nodes, ended } = parse(tokens, pos, [])
  if (ended) {
    throw new TemplateError(`unexpected {{ ${ended} }}`)
  }
  return nodes
}

function lookup(path: string, dot: unknown, root: unknown): unknown {
  let base: unknown
  let rest: string
  if (path.startsWith("$")) {
    base = root
    rest = path.slice(path.startsWith("$.") ? 2 : 1)
  } else {
    base = dot
    rest = path.slice(1)
  }
  if (!rest) {
    return base
  }
  let value: unknown = base
  for (const key of rest.split(".")) {
    if (value === null || value === undefined || typeof value !== "object") {
      return undefined
    }
    value = (value as Record<string, unknown>)[key]
  }
  return value
}

// truthy follows Go: false, 0, "", nil and empty lists or maps are false.
function truthy(value: unknown): boolean {
  if (Array.isArray(value)) {
    return value.length > 0
  }
  if (value && typeof value === "object") {
    return Object.keys(value).length > 0
  }
  return Boolean(value)
}

export function escapeHTML(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&#34;")
    .replace(/'/g, "&#39;")
}

function display(value: unknown): string {
  if (value === null || value === undefined) {
    return ""
  }
  if (value instanceof Date) {
    return value.toISOString()
  }
  if (typeof value === "object") {
    return JSON.stringify(value)
  }
  return String(value)
}

function run(nodes: Node[], dot: unknown, root: unknown, escape: boolean): string {
  let out = ""
  for (const node of nodes) {
    switch (node.kind) {
      case "text":
        out += node.text
        break
      case "value": {
        const text = display(lookup(node.path, dot, root))
        out += node.raw || !escape ? text : escapeHTML(text)
        break
      }
      case "if":
        out += run(truthy(lookup(node.path, dot, root)) ? node.then : node.else, dot, root, escape)
        break
      case "range": {
        const list = lookup(node.path, dot, root)
        if (Array.isArray(list) && list.length) {
          for (const item of list) {
            out += run(node.body, item, root, escape)
          }
        } else {
          out += run(node.else, dot, root, escape)
        }
        break
      }
    }
  }
  return out
}

// renderHTML renders an e-mail body: values are escaped unless raw.
export function renderHTML(source: string, data: unknown): string {
  return run(compile(source), data, data, true)
}

// renderText renders a subject line: plain text, nothing escaped.
export function renderText(source: string, data: unknown): string {
  return run(compile(source), data, data, false).replace(/\s+/g, " ").trim()
}

// checkTemplate reports the first syntax error, or undefined when it parses.
export function checkTemplate(source: string): string | undefined {
  try {
    compile(source)
    return undefined
  } catch (error) {
    if (error instanceof TemplateError) {
      return error.message
    }
    throw error
  }
}
