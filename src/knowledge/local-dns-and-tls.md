# Local DNS and TLS: why a new machine needed six manual steps

Every gosite project is served at `https://<name>.test` through the shared
Traefik proxy. Two things have to be true for a browser to open that, and
neither is Docker:

1. `*.test` resolves to `127.0.0.1`.
2. The certificate Traefik serves is signed by a CA the browser trusts.

Both were undocumented manual steps until 0.50.0. `gosite setup` does them now,
after printing what it will change. This file is why each step exists, because
the commands look arbitrary without it.

## DNS

`.test` is reserved by RFC 6761 for exactly this, and no public resolver
answers for it. Something local has to.

**macOS** has a resolver-per-TLD mechanism: a file at `/etc/resolver/test`
naming `127.0.0.1` sends only `.test` lookups to the local dnsmasq. Nothing
else changes.

**Ubuntu** has no equivalent, and this is where the time goes:

- `systemd-resolved` runs a stub listener that owns port 53. dnsmasq cannot
  start while it does, and the failure is a service that "did not start"
  rather than anything mentioning a port. `DNSStubListener=no` in
  `/etc/systemd/resolved.conf` frees it.
- Turning the stub off means `/etc/resolv.conf` must point at
  `/run/systemd/resolve/resolv.conf` instead of the stub address, or the
  machine loses DNS entirely.
- resolved then needs to be told where `.test` lives:
  `DNS=127.0.0.1` + `Domains=~test` in a drop-in. The `~` makes it a routing
  domain - only `.test` goes to dnsmasq, everything else keeps its normal
  path.
- dnsmasq gets `address=/.test/127.0.0.1`.

**NetworkManager runs its own dnsmasq** when configured with `dns=dnsmasq`,
and then two processes want `127.0.0.1:53`. gosite checks which one is active
and configures exactly one. Configuring both is the failure that looks like
DNS working intermittently.

The check that matters is not "is dnsmasq installed" but
`getent hosts anything.test` - the resolver path an application actually
takes. That is what `dns_resolves()` probes.

## Certificates

`mkcert -install` creates a local CA and installs it into the system trust
store. Two things about that are not obvious.

**On Ubuntu it does not install anything.** It prints "Installing to the
system store is not yet supported on this Linux", exits 0, and leaves the CA
in `~/.local/share/mkcert/`. Every check based on "does rootCA.pem exist"
passes, and curl, wget and git still reject the certificates. gosite copies it
to `/usr/local/share/ca-certificates/` and runs `update-ca-certificates`.

**Browsers do not read the system store.** Chromium, Brave, Chrome and Firefox
each carry an NSS database (`~/.local/share/pki/nssdb`, `~/.pki/nssdb`, and one
per Firefox profile) and consult that instead. A CA correctly installed
system-wide is invisible to them, which is how a valid certificate still shows
`ERR_CERT_AUTHORITY_INVALID`. `certutil -A -t "C,,"` per database fixes it, and
a running browser holds a lock on `cert9.db`, so it has to be closed.

## The certificate that exists and is never used

Traefik reads certificates from a watched dynamic directory. gosite writes one
`~/.gosite/traefik/dynamic/<project>.yml` per project pointing at its `.pem`.

`ensure_project_cert` used to check only whether the two `.pem` files existed.
When the `.yml` went missing - a partially cleaned `~/.gosite`, a stack brought
up with docker compose directly instead of `gosite start` - the certificate sat
on disk, correct and unreferenced, while Traefik served `TRAEFIK DEFAULT CERT`
and the browser refused it. It now re-writes the dynamic file whenever the
certificate is good, and re-issues when the certificate does not cover
`<name>.test` and `*.<name>.test`.

**Read the SAN with `-text`, not `-ext subjectAltName`.** macOS ships
LibreSSL, which has no `-ext` and answers "unknown option". Reading that as
"covers nothing" re-issues every certificate on every start, on the one
platform where they were all fine.
