# tls-dns

TLS termination and DNS for the public-facing hostnames. Caddy owns both.

**Status: DOCUMENTED 2026-09-08** (was an UNDOCUMENTED stub). Claims tagged
**[M]** machine-verified, **[C]** needs confirmation, or
**unknown — nobody knows**.

---

# 🛑 THESE ENDPOINTS ARE INTERNET-FACING

**[M] Verified 2026-09-08.** All three hostnames resolve on **public DNS**
(queried via `1.1.1.1`) to `51.112.42.49`, which is **this host's own public
IP**:

```
sghprod.iohealth.com       -> 51.112.42.49
bge-m3.dev.iohealth.com    -> 51.112.42.49
rag.dev.iohealth.com       -> 51.112.42.49
this host's public IP      == 51.112.42.49
```

**[M]** Caddy runs with `network=host` and listens on `*:80` and `*:443` — all
interfaces, not loopback.

**[M]** Inbound reachability from the internet is *proven*, not assumed:
Let's Encrypt certificates were issued and are being renewed for these names.
ACME HTTP-01/TLS-ALPN-01 validation requires the internet to reach port 80/443
on this host. Caddy's log shows live renewal scheduling for `bge-m3.dev` and
`rag.dev`.

**[M] The only thing in front of the RAG services is an `X-API-Key` header
match in Caddy.** No IP allowlist, no mTLS, no VPN, no OIDC on that path.
Present the right header from anywhere on the internet and you reach the
service; present nothing and you get a 401.

**This corrects an earlier belief that these were internal-only.** They are not.
That changes what may be written in a synced repo — no key values, no corpus
contents, no path enumeration beyond what is already here.

---

## Certificates

**[M]** Let's Encrypt via Caddy's built-in ACME. Contact email is a colleague's
address, not the owner's — **[C]** confirm who receives expiry warnings.

| Host | Expires | Days left | Routed in Caddyfile? | Auto-renews? |
|---|---|---|---|---|
| `sghprod.iohealth.com` | 2026-09-30 | **22** | **NO** | **NO — see below** |
| `bge-m3.dev.iohealth.com` | 2026-10-20 | 42 | yes | yes |
| `rag.dev.iohealth.com` | 2026-11-09 | 62 | yes | yes |

**[M]** Cert store on the host:
`/var/lib/docker/volumes/caddy_data/_data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/<host>/`

**[M]** Check any expiry without waiting for a failure:

```bash
sudo find /var/lib/docker/volumes/caddy_data/_data/caddy/certificates \
  -name '*.crt' -exec sh -c \
  'echo "$1: $(openssl x509 -enddate -noout -in "$1")"' _ {} \;
```

### ⚠️ `sghprod.iohealth.com` will expire and will NOT renew

**[M]** It has a valid cert with 22 days left, but **it does not appear anywhere
in the 33-line Caddyfile**. Caddy only manages certificates for hosts it is
configured to serve, so this one is orphaned in the cert store and no renewal
will happen. Let's Encrypt certs are 90 days and Caddy renews at roughly 30 days
remaining — that window has already passed without action, which is the
confirmation that it is unmanaged.

**unknown — nobody knows:** what `sghprod.iohealth.com` serves, whether anything
still calls it, and whether it moved to another host. Its DNS still points here.

**Decision required before 2026-09-30.** See `../oncall.md` blocking item B3.

## Routing

**[M]** `/home/ubuntu/caddy/Caddyfile`, 33 lines, bind-mounted read-only into
the `caddy` container at `/etc/caddy/Caddyfile`.

| Host / path | Auth | Backend |
|---|---|---|
| `bge-m3.dev…` | **none in Caddy** — the vLLM server's own key | `127.0.0.1:8000` |
| `rag.dev…/cortex/*` | `X-API-Key` = cortex key | `127.0.0.1:8320` unified RAG |
| `rag.dev…` (current key) | `X-API-Key` | `127.0.0.1:8081` hybrid |
| `rag.dev…` (v2 key) | `X-API-Key` | `127.0.0.1:8081` — **same backend** |
| `rag.dev…` (legacy key) | `X-API-Key` | `127.0.0.1:8080` legacy service |
| anything else | — | `401 Unauthorized` |

**[M]** Routing is rewritten by
`scripts/configure_dual_rag_route.sh`, which perl-substitutes the `rag.dev`
block, then validates and reloads Caddy over stdin. Its own comment explains
why stdin: an in-place host edit can replace the inode behind the read-only
bind mount, so re-reading the file path could see the old inode.

**[M]** Do not hand-edit the `rag.dev` block — that script will overwrite it.

## ⚠️ There is no access log

**[M] Zero `log` directives in the Caddyfile.** Nothing records who calls these
internet-facing endpoints — no source IP, no user-agent, no timestamp, no
key-used.

The consequence, hit immediately on 2026-09-08: after the `bge-m3` server key
was rotated, there was **no way to identify which callers broke**. The only
401s visible were from the Docker bridge gateway `172.17.0.1` — the operator's
own verification probes. Absence of logged 401s is **not** evidence of no
affected callers; it is evidence of no logging.

**Recommended, and cheap:** add access logging to both site blocks so the next
key rotation, or the next incident, has evidence.

```
# inside each site block
log {
    output file /var/log/caddy/access.log {
        roll_size 50MiB
        roll_keep 10
    }
}
```

**[C]** Confirm before adding — an access log on this path will record source
IPs of callers, which may itself be sensitive.

## Health check

```bash
sudo docker ps --filter name=caddy --format '{{.Names}} {{.Status}}'
sudo ss -tlnp | awk '$4 ~ /:(80|443)$/'          # expect caddy on *:80 and *:443
sudo docker exec -i caddy caddy validate --config - --adapter caddyfile \
  < /home/ubuntu/caddy/Caddyfile
echo | openssl s_client -connect rag.dev.iohealth.com:443 \
  -servername rag.dev.iohealth.com 2>/dev/null | openssl x509 -enddate -noout
```

## Symptom → diagnosis → fix

| Symptom | Cause | Check | Fix |
|---|---|---|---|
| All clients fail TLS; service healthy | certificate expired | `openssl s_client` above | if the host is routed, Caddy renews automatically — check `docker logs caddy` for ACME errors. If unrouted (like `sghprod`), it will never renew |
| 401 on every request | wrong or missing `X-API-Key`, or the key was rotated | which of the four keys the caller sends | re-issue via `configure_dual_rag_route.sh`; there is no access log to tell you who broke |
| Caddy reload appears to do nothing | in-place edit replaced the inode behind the read-only bind mount | reload via stdin, as the script does | `caddy reload --config - < Caddyfile` |
| Renewal fails | inbound 80/443 blocked, or DNS moved off this host | `docker logs caddy \| grep acme` | restore inbound reachability; ACME needs it |

## Looks broken, isn't

- **[M]** `docker ps` shows **no published ports** for `caddy`. Correct — it is
  `network=host`, so it binds the host's `:80`/`:443` directly.
- **[M]** All backends bind `127.0.0.1`. Correct — only Caddy is public; the
  services are reachable solely through it.
- **[M]** Two different keys routing to the same `:8081` backend is the current
  state, not a mistake to "clean up" — see `rag-stack.md`.

## Do NOT

- **[M] Do not hand-edit the `rag.dev` block** in the Caddyfile;
  `configure_dual_rag_route.sh` regenerates it and will discard your change.
- **[M] Do not reload Caddy by pointing at the file path** after an in-place
  edit. Feed the config on stdin.
- **[M] Do not assume these hosts are internal.** They are on public DNS,
  public IP, and reachable from the internet.
- **[M] Do not delete the `sghprod` cert directory** to silence the expiry until
  someone establishes what that hostname serves.
- **[C] Do not rotate a key on these services without an access log in place**
  or a known caller list. There is currently neither.

## Escalation

**unknown — nobody knows** who owns DNS for `iohealth.com`, or who can change a
record. The Caddy ACME contact email is a colleague's; **[C]** confirm whether
they are the DNS owner or merely the address that was to hand.
