import test from "node:test"
import assert from "node:assert/strict"

import { checkTemplate, renderHTML, renderText } from "../../src/lib/mailer/template.ts"

const data = {
  store: { name: "Aldu" },
  order: {
    display_id: 12,
    note: "<b>urgente</b>",
    items: [
      { title: "Bota", quantity: 2 },
      { title: "Casco <XL>", quantity: 1 },
    ],
    shipping_address: { first_name: "Ana" },
  },
}

test("values are escaped, raw ones are not, missing ones render empty", () => {
  assert.equal(renderHTML("#{{ .order.display_id }} {{ .order.note }}", data), "#12 &lt;b&gt;urgente&lt;/b&gt;")
  assert.equal(renderHTML("{{ raw .order.note }}", data), "<b>urgente</b>")
  assert.equal(renderHTML("[{{ .order.missing.deep }}]", data), "[]")
})

test("range sets the scope to each item and $ stays the root", () => {
  const html = renderHTML("{{ range .order.items }}{{ .title }}×{{ .quantity }} {{ $.store.name }};{{ end }}", data)
  assert.equal(html, "Bota×2 Aldu;Casco &lt;XL&gt;×1 Aldu;")
  assert.equal(renderHTML("{{ range .order.none }}x{{ else }}empty{{ end }}", data), "empty")
})

test("if follows Go's truthiness and supports else", () => {
  assert.equal(renderHTML("{{ if .order.shipping_address }}to {{ .order.shipping_address.first_name }}{{ end }}", data), "to Ana")
  assert.equal(renderHTML("{{ if .order.items }}yes{{ else }}no{{ end }}", { order: { items: [] } }), "no")
  assert.equal(renderHTML("{{ if .n }}yes{{ else }}no{{ end }}", { n: 0 }), "no")
  assert.equal(renderHTML("{{/* note */}}ok", data), "ok")
})

test("subjects are plain text on one line", () => {
  assert.equal(renderText("Pedido  #{{ $.order.display_id }}\n {{ .order.note }}", data), "Pedido #12 <b>urgente</b>")
})

test("syntax errors are reported, not rendered", () => {
  assert.match(checkTemplate("{{ if .a }}x") ?? "", /no \{\{ end \}\}/)
  assert.match(checkTemplate("{{ end }}") ?? "", /has no/)
  assert.match(checkTemplate("{{ .a") ?? "", /unclosed/)
  assert.match(checkTemplate("{{ order.id }}") ?? "", /not a value/)
  assert.equal(checkTemplate("{{ range $.order.items }}{{ . }}{{ end }}"), undefined)
  assert.throws(() => renderHTML("{{ if .a }}", {}))
})
