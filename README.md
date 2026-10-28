# rockheart

An Ansible-deployed [Xray](https://github.com/XTLS/Xray-core) exit node built to survive DPI (deep packet inspection, as in Russia's TSPU).

Anyone who connects without valid credentials (an active probe, a scanner, a browser) is transparently proxied to a real, popular HTTPS site. They get that site's genuine certificate and content. Only your users get a tunnel.

## How it works

```
client ──TLS (REALITY, SNI = reality_target)──► :443  VLESS + REALITY + Vision
                                                  ├─ Vision client        → tunnel
                                                  ├─ XHTTP client         → fallback → @xhttp (VLESS + XHTTP) → tunnel
                                                  └─ anyone else          → relayed to the real reality_target:443
```

- **REALITY**: the TLS handshake is indistinguishable from a real connection to `reality_target`. No domain or certificate of your own is needed, and active probes see the real site.
- **XHTTP** (primary profile): the tunnel is split into ordinary-looking HTTP/2 requests with random padding. This hides the traffic shape after the handshake, which is what TSPU started fingerprinting in 2026.
- **Vision** (fallback profile): classic `xtls-rprx-vision` over raw TCP. It is faster, and you can switch to it if XHTTP misbehaves on some network.
- Both profiles share port 443, the SNI and the keys. Each user gets one link per profile.
- Hardening:
  - Xray runs as an unprivileged systemd service with a sandboxed unit.
  - ufw allows only SSH and 443.
  - BBR is enabled.
  - Unattended security upgrades are on.
  - The server blocks proxying to private IP ranges and BitTorrent.

## Requirements

- **VPS**: Debian 12 or Ubuntu 22.04+ (x86_64 or arm64), outside the censored network, with root SSH access by key.
- **Control machine**:
  - `ansible-core` ≥ 2.17
  - optionally `qrencode` for QR codes (`brew install qrencode`)
  - Docker, only for `make test`

## Quick start

```sh
make deps                                         # install Ansible collections
cp inventory/hosts.example.yml inventory/hosts.yml
$EDITOR inventory/hosts.yml                       # server IP, users, reality_target
make deploy
```

Client links and QR codes end up in `clients/<host>/<user>/`:

| File | Profile |
|---|---|
| `xhttp.txt` / `xhttp.png` | VLESS + REALITY + XHTTP: use this by default |
| `vision.txt` / `vision.png` | VLESS + REALITY + Vision: fallback |

Import the links into a client that ships a recent Xray core: Hiddify, v2RayTun, Happ, v2rayN, Streisand or FoXray. Keep the client updated, since XHTTP and REALITY change quickly. The links already set `fp=chrome`; don't change it.

## Choosing `reality_target`

Requirements for the site you borrow:

- **TLS 1.3 and HTTP/2.** The playbook checks TLS 1.3 with `xray tls ping` and refuses to continue without it. It also warns if the site lacks the post-quantum key exchange that Chrome uses.
- **Not blocked or throttled in Russia.** A site that's unreachable from inside the country makes your server suspicious.
- **Plausible for your server's IP.** Ideally pick a site hosted by the same provider or ASN as your VPS. A foreign VPS IP claiming to be `www.microsoft.com` is weaker camouflage than one serving a site that really lives in that datacenter.
- **Doesn't redirect** its root to another host.

Re-check a target any time with `make check-target`, which prints the full TLS ping report from the server.

## Day-to-day

| Task | How |
|---|---|
| Add or remove a user | Edit `xray_users`, run `make deploy`. Removed users stop working immediately. |
| Regenerate links/QR codes only | `make clients` |
| Upgrade Xray | Set `xray_version` and both `xray_release_sha256` values (from the release's `.zip.dgst` files) in `inventory/hosts.yml`, or update the defaults in `roles/xray/defaults/main.yml`. Then run `make deploy`. |
| Move to a new server | Add the host to the inventory and deploy. Each host gets its own keys and links. |

Useful variables (defaults in `roles/*/defaults/main.yml`):

| Variable | Default | Meaning |
|---|---|---|
| `xray_users` | required | User names, `[a-z0-9_-]` |
| `reality_target` | required | Hostname to impersonate (no port) |
| `xray_port` | `443` | Public port |
| `xray_xhttp_mode` | `auto` | XHTTP mode; the client may override it |
| `clients_server_address` | `ansible_host` | Address written into links, e.g. a DNS name |
| `common_firewall_enabled` | `true` | Manage ufw |
| `common_ssh_harden` | `false` | Disable SSH password login |

## Secrets

- **`credentials/<host>/`** (git-ignored) is the source of truth for user UUIDs, shortIds and the XHTTP path. Back it up: if it's lost, the next deploy issues new credentials and every client has to re-import.
- **The REALITY private key** is generated on the server and never leaves it (`/usr/local/etc/xray/reality.key`).
- **`clients/`** (git-ignored) holds generated links. Treat them like passwords.

## Testing

```sh
make lint   # ansible-lint + syntax check
make test   # full end-to-end run in Docker
```

`make test` runs these steps:

1. Deploys the playbook into a systemd Debian 12 container.
2. Runs it a second time and requires `changed=0`.
3. Starts a client container that has **no internet access** except through the server.
4. Checks that the internet is reachable through both the XHTTP and the Vision link.
5. Checks that an unauthenticated TLS connection to the server returns the real `reality_target` site with a valid certificate.

## Caveats

- This hides *what* your traffic is, not *where* it goes. A VPS IP can still be blocked outright, and high sustained traffic to one foreign IP is itself a signal. Have a spare server.
- Some mobile networks in Russia restrict traffic to whitelisted destinations. A single foreign exit node can't solve that. It needs a relay inside the country, which this repo doesn't set up.
