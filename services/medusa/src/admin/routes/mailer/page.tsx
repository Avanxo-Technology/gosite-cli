import { defineRouteConfig } from "@medusajs/admin-sdk"
import { Envelope } from "@medusajs/icons"
import {
  Badge,
  Button,
  Container,
  Heading,
  Input,
  Label,
  Select,
  Switch,
  Table,
  Tabs,
  Text,
  Textarea,
  toast,
  Toaster,
} from "@medusajs/ui"
import { useCallback, useEffect, useState } from "react"

// Admin › Mailer: the store's e-mail rules (event → recipient → subject and
// HTML), a preview rendered with a real order, test sends and the log of what
// was sent. Backed by /admin/mailer/* (src/api/admin/mailer).

type Recipient = "order_email" | "customer_email" | "event_email" | "custom"

type Rule = {
  id?: string
  name: string
  event: string
  active: boolean
  recipient: Recipient
  recipient_address: string | null
  bcc: string | null
  subject: string
  html: string
  once: boolean
}

type Starter = { key: string; label: string; event: string; recipient: Recipient; subject: string; html: string }

type Meta = {
  events: string[]
  gosite_events: string[]
  starters: Starter[]
  variables: Array<{ name: string; description: string }>
  smtp: { configured: boolean; from: string | null; host: string | null }
}

type Delivery = {
  id: string
  rule_id: string
  event: string
  resource_id: string | null
  to: string
  subject: string
  status: "pending" | "sent" | "failed" | "skipped"
  attempts: number
  last_error: string | null
  sent_at: string | null
  created_at: string
}

const RECIPIENT_LABELS: Record<Recipient, string> = {
  order_email: "The order's e-mail",
  customer_email: "The customer's e-mail",
  event_email: "The event's email field (custom events)",
  custom: "Fixed addresses",
}

async function api<T>(path: string, init?: { method?: string; body?: unknown }): Promise<T> {
  const response = await fetch(`/admin/mailer${path}`, {
    method: init?.method ?? "GET",
    credentials: "include",
    headers: init?.body ? { "Content-Type": "application/json" } : undefined,
    body: init?.body ? JSON.stringify(init.body) : undefined,
  })
  const json = await response.json().catch(() => ({}))
  if (!response.ok) {
    throw Object.assign(new Error(json.error || json.message || `HTTP ${response.status}`), { body: json })
  }
  return json as T
}

function fromStarter(starter: Starter): Rule {
  return {
    name: starter.key === "blank" ? "" : starter.label,
    event: starter.event,
    active: false,
    recipient: starter.recipient,
    recipient_address: null,
    bcc: null,
    subject: starter.subject,
    html: starter.html,
    once: true,
  }
}

const STATUS_COLOR: Record<Delivery["status"], "green" | "red" | "orange" | "grey"> = {
  sent: "green",
  failed: "red",
  pending: "orange",
  skipped: "grey",
}

function Editor({ meta, initial, onSaved, onCancel }: { meta: Meta; initial: Rule; onSaved: () => void; onCancel: () => void }) {
  const [rule, setRule] = useState<Rule>(initial)
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [saving, setSaving] = useState(false)
  const [preview, setPreview] = useState<{ html: string; subject: string; to: string[]; sample: string } | null>(null)
  const [previewError, setPreviewError] = useState<string | null>(null)
  const [orderID, setOrderID] = useState("")
  const [testTo, setTestTo] = useState("")

  const set = <K extends keyof Rule>(key: K, value: Rule[K]) => setRule((r) => ({ ...r, [key]: value }))

  const runPreview = useCallback(async () => {
    try {
      const result = await api<{ html: string; subject: string; to: string[]; sample: string }>("/preview", {
        method: "POST",
        body: { ...rule, order_id: orderID || undefined },
      })
      setPreview(result)
      setPreviewError(null)
    } catch (error) {
      setPreviewError((error as Error).message)
    }
  }, [rule, orderID])

  useEffect(() => {
    const timer = setTimeout(runPreview, 600)
    return () => clearTimeout(timer)
  }, [runPreview])

  const save = async () => {
    setSaving(true)
    try {
      await api(rule.id ? `/rules/${rule.id}` : "/rules", { method: "POST", body: rule })
      toast.success("Rule saved")
      onSaved()
    } catch (error) {
      const body = (error as { body?: { errors?: Record<string, string> } }).body
      setErrors(body?.errors ?? {})
      toast.error(body?.errors ? "Check the highlighted fields" : (error as Error).message)
    } finally {
      setSaving(false)
    }
  }

  const sendTest = async () => {
    try {
      const result = await api<{ to: string; sample: string }>("/send-test", {
        method: "POST",
        body: { ...rule, to: testTo, order_id: orderID || undefined },
      })
      toast.success(`Test sent to ${result.to} (${result.sample})`)
    } catch (error) {
      toast.error((error as Error).message)
    }
  }

  const field = (key: string) => (errors[key] ? <Text size="small" className="text-ui-fg-error">{errors[key]}</Text> : null)

  return (
    <div className="flex flex-col gap-y-4 px-6 py-4">
      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
        <div className="flex flex-col gap-y-1">
          <Label htmlFor="name">Name</Label>
          <Input id="name" value={rule.name} onChange={(e) => set("name", e.target.value)} />
          {field("name")}
        </div>
        <div className="flex flex-col gap-y-1">
          <Label>Event</Label>
          <Select value={rule.event} onValueChange={(value) => set("event", value)}>
            <Select.Trigger>
              <Select.Value placeholder="Pick an event" />
            </Select.Trigger>
            <Select.Content>
              {meta.events.map((event) => (
                <Select.Item key={event} value={event}>
                  {event}
                  {meta.gosite_events.includes(event) ? " (gosite)" : ""}
                </Select.Item>
              ))}
            </Select.Content>
          </Select>
          {field("event")}
        </div>
        <div className="flex flex-col gap-y-1">
          <Label>Send to</Label>
          <Select value={rule.recipient} onValueChange={(value) => set("recipient", value as Recipient)}>
            <Select.Trigger>
              <Select.Value />
            </Select.Trigger>
            <Select.Content>
              {(Object.keys(RECIPIENT_LABELS) as Recipient[]).map((key) => (
                <Select.Item key={key} value={key}>
                  {RECIPIENT_LABELS[key]}
                </Select.Item>
              ))}
            </Select.Content>
          </Select>
          {field("recipient")}
        </div>
        {rule.recipient === "custom" ? (
          <div className="flex flex-col gap-y-1">
            <Label htmlFor="recipient_address">Addresses</Label>
            <Input
              id="recipient_address"
              placeholder="ventas@example.com, bodega@example.com"
              value={rule.recipient_address ?? ""}
              onChange={(e) => set("recipient_address", e.target.value)}
            />
            {field("recipient_address")}
          </div>
        ) : (
          <div className="flex flex-col gap-y-1">
            <Label htmlFor="bcc">Bcc (optional)</Label>
            <Input id="bcc" placeholder="ventas@example.com" value={rule.bcc ?? ""} onChange={(e) => set("bcc", e.target.value)} />
            {field("bcc")}
          </div>
        )}
      </div>
      <div className="flex flex-wrap items-center gap-x-6 gap-y-2">
        <div className="flex items-center gap-x-2">
          <Switch id="active" checked={rule.active} onCheckedChange={(checked) => set("active", checked)} />
          <Label htmlFor="active">Active: send on this event</Label>
        </div>
        <div className="flex items-center gap-x-2">
          <Switch id="once" checked={rule.once} onCheckedChange={(checked) => set("once", checked)} />
          <Label htmlFor="once">Once per order or customer</Label>
        </div>
      </div>
      <div className="flex flex-col gap-y-1">
        <Label htmlFor="subject">Subject</Label>
        <Input id="subject" value={rule.subject} onChange={(e) => set("subject", e.target.value)} />
        {field("subject")}
      </div>
      <div className="grid grid-cols-1 gap-4 xl:grid-cols-2">
        <div className="flex flex-col gap-y-1">
          <Label htmlFor="html">HTML</Label>
          <Textarea
            id="html"
            rows={28}
            spellCheck={false}
            className="font-mono text-xs"
            value={rule.html}
            onChange={(e) => set("html", e.target.value)}
          />
          {field("html")}
          <details className="mt-2">
            <summary className="cursor-pointer text-ui-fg-subtle text-sm">Variables</summary>
            <Text size="small" className="mt-2 text-ui-fg-subtle">
              Go template style: {"{{ $.order.display_id }}"}, {"{{ if … }} … {{ else }} … {{ end }}"},{" "}
              {"{{ range $.order.items }} {{ .title }} {{ end }}"}, {"{{ raw … }}"} writes HTML unescaped.
            </Text>
            <ul className="mt-2 flex flex-col gap-y-1">
              {meta.variables.map((v) => (
                <li key={v.name}>
                  <Text size="small">
                    <code>{v.name}</code> <span className="text-ui-fg-subtle">— {v.description}</span>
                  </Text>
                </li>
              ))}
            </ul>
          </details>
        </div>
        <div className="flex flex-col gap-y-2">
          <div className="flex items-end gap-x-2">
            <div className="flex flex-1 flex-col gap-y-1">
              <Label htmlFor="order">Preview with order id (empty: the latest)</Label>
              <Input id="order" placeholder="order_…" value={orderID} onChange={(e) => setOrderID(e.target.value)} />
            </div>
          </div>
          {previewError ? <Text size="small" className="text-ui-fg-error">{previewError}</Text> : null}
          {preview ? (
            <>
              <Text size="small" className="text-ui-fg-subtle">
                {preview.sample} · to: {preview.to.join(", ") || "nobody (no address for this recipient)"}
              </Text>
              <Text weight="plus">{preview.subject}</Text>
              <iframe title="preview" sandbox="" srcDoc={preview.html} className="h-[560px] w-full rounded-md border border-ui-border-base bg-white" />
            </>
          ) : null}
          <div className="flex items-end gap-x-2">
            <div className="flex flex-1 flex-col gap-y-1">
              <Label htmlFor="test-to">Send a test to</Label>
              <Input id="test-to" type="email" placeholder="you@example.com" value={testTo} onChange={(e) => setTestTo(e.target.value)} />
            </div>
            <Button variant="secondary" onClick={sendTest} disabled={!meta.smtp.configured || !testTo}>
              Send test
            </Button>
          </div>
        </div>
      </div>
      <div className="flex justify-end gap-x-2">
        <Button variant="secondary" onClick={onCancel}>
          Cancel
        </Button>
        <Button onClick={save} isLoading={saving}>
          Save
        </Button>
      </div>
    </div>
  )
}

const MailerPage = () => {
  const [meta, setMeta] = useState<Meta | null>(null)
  const [rules, setRules] = useState<Array<Rule & { id: string }>>([])
  const [deliveries, setDeliveries] = useState<Delivery[]>([])
  const [editing, setEditing] = useState<Rule | null>(null)
  const [starter, setStarter] = useState("order_paid")

  const load = useCallback(async () => {
    const [m, r, d] = await Promise.all([
      api<Meta>("/meta"),
      api<{ rules: Array<Rule & { id: string }> }>("/rules"),
      api<{ deliveries: Delivery[] }>("/deliveries"),
    ])
    setMeta(m)
    setRules(r.rules)
    setDeliveries(d.deliveries)
  }, [])

  useEffect(() => {
    load().catch((error) => toast.error((error as Error).message))
  }, [load])

  const remove = async (rule: Rule & { id: string }) => {
    if (!window.confirm(`Delete "${rule.name}"?`)) {
      return
    }
    await api(`/rules/${rule.id}`, { method: "DELETE" })
    toast.success("Rule deleted")
    await load()
  }

  const toggle = async (rule: Rule & { id: string }) => {
    await api(`/rules/${rule.id}`, { method: "POST", body: { ...rule, active: !rule.active } })
    await load()
  }

  if (!meta) {
    return (
      <Container>
        <Text>Loading…</Text>
      </Container>
    )
  }

  const ruleName = (id: string) => rules.find((r) => r.id === id)?.name ?? id

  return (
    <Container className="divide-y p-0">
      <Toaster />
      <div className="flex flex-wrap items-center justify-between gap-2 px-6 py-4">
        <div>
          <Heading level="h1">Mailer</Heading>
          <Text size="small" className="text-ui-fg-subtle">
            {meta.smtp.configured
              ? `Sending through ${meta.smtp.host} as ${meta.smtp.from}`
              : "SMTP is not configured (SMTP_HOST, SMTP_FROM): rules are kept but nothing is sent."}
          </Text>
        </div>
        {editing ? null : (
          <div className="flex items-center gap-x-2">
            <Select value={starter} onValueChange={setStarter}>
              <Select.Trigger className="w-56">
                <Select.Value />
              </Select.Trigger>
              <Select.Content>
                {meta.starters.map((s) => (
                  <Select.Item key={s.key} value={s.key}>
                    Start from: {s.label}
                  </Select.Item>
                ))}
              </Select.Content>
            </Select>
            <Button onClick={() => setEditing(fromStarter(meta.starters.find((s) => s.key === starter) ?? meta.starters[0]))}>
              New rule
            </Button>
          </div>
        )}
      </div>
      {editing ? (
        <Editor
          key={editing.id ?? "new"}
          meta={meta}
          initial={editing}
          onCancel={() => setEditing(null)}
          onSaved={async () => {
            setEditing(null)
            await load()
          }}
        />
      ) : (
        <Tabs defaultValue="rules">
          <Tabs.List className="px-6 pt-4">
            <Tabs.Trigger value="rules">Rules</Tabs.Trigger>
            <Tabs.Trigger value="log">Sent e-mails</Tabs.Trigger>
          </Tabs.List>
          <Tabs.Content value="rules" className="py-4">
            {rules.length ? (
              <Table>
                <Table.Header>
                  <Table.Row>
                    <Table.HeaderCell>Name</Table.HeaderCell>
                    <Table.HeaderCell>Event</Table.HeaderCell>
                    <Table.HeaderCell>To</Table.HeaderCell>
                    <Table.HeaderCell>Active</Table.HeaderCell>
                    <Table.HeaderCell />
                  </Table.Row>
                </Table.Header>
                <Table.Body>
                  {rules.map((rule) => (
                    <Table.Row key={rule.id}>
                      <Table.Cell>{rule.name}</Table.Cell>
                      <Table.Cell>
                        <code>{rule.event}</code>
                      </Table.Cell>
                      <Table.Cell>{rule.recipient === "custom" ? rule.recipient_address : RECIPIENT_LABELS[rule.recipient]}</Table.Cell>
                      <Table.Cell>
                        <Switch checked={rule.active} onCheckedChange={() => toggle(rule)} />
                      </Table.Cell>
                      <Table.Cell className="text-right">
                        <Button size="small" variant="secondary" onClick={() => setEditing(rule)}>
                          Edit
                        </Button>{" "}
                        <Button size="small" variant="danger" onClick={() => remove(rule)}>
                          Delete
                        </Button>
                      </Table.Cell>
                    </Table.Row>
                  ))}
                </Table.Body>
              </Table>
            ) : (
              <Text className="px-6 text-ui-fg-subtle">No rules yet: nothing is e-mailed. Create one from a starting template.</Text>
            )}
          </Tabs.Content>
          <Tabs.Content value="log" className="py-4">
            {deliveries.length ? (
              <Table>
                <Table.Header>
                  <Table.Row>
                    <Table.HeaderCell>When</Table.HeaderCell>
                    <Table.HeaderCell>Rule</Table.HeaderCell>
                    <Table.HeaderCell>To</Table.HeaderCell>
                    <Table.HeaderCell>Subject</Table.HeaderCell>
                    <Table.HeaderCell>Status</Table.HeaderCell>
                  </Table.Row>
                </Table.Header>
                <Table.Body>
                  {deliveries.map((d) => (
                    <Table.Row key={d.id} title={d.last_error ?? ""}>
                      <Table.Cell>{new Date(d.created_at).toLocaleString()}</Table.Cell>
                      <Table.Cell>
                        {ruleName(d.rule_id)} <span className="text-ui-fg-subtle">· {d.event}</span>
                      </Table.Cell>
                      <Table.Cell>{d.to || "—"}</Table.Cell>
                      <Table.Cell>{d.subject}</Table.Cell>
                      <Table.Cell>
                        <Badge color={STATUS_COLOR[d.status]} size="2xsmall">
                          {d.status}
                          {d.attempts > 1 ? ` ×${d.attempts}` : ""}
                        </Badge>
                        {d.last_error ? <Text size="xsmall" className="text-ui-fg-subtle">{d.last_error}</Text> : null}
                      </Table.Cell>
                    </Table.Row>
                  ))}
                </Table.Body>
              </Table>
            ) : (
              <Text className="px-6 text-ui-fg-subtle">Nothing sent yet.</Text>
            )}
          </Tabs.Content>
        </Tabs>
      )}
    </Container>
  )
}

export const config = defineRouteConfig({
  label: "Mailer",
  icon: Envelope,
})

export default MailerPage
