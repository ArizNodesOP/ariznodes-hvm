# Ariznodes™ HVM Panel

A self-hosted control panel for giving out and managing **LXC containers, KVM virtual machines and Docker containers**. Users earn servers by inviting real people to your Discord server, and a verification bot builds the server for them. It ships with SSH and browser terminals, snapshots, multi-node support, an API, and a security-first login.

> © 2026 Ariznodes™. All rights reserved. See [LICENSE](LICENSE).

---

## Features

**For users**
- Register, link Discord, and deploy a server once you have enough verified invites (2 / 4 / 8 / 12 / 20 for basic / medium / large / pro / elite)
- Choose **LXC container**, **KVM virtual machine** or **Docker container** when deploying (each is separate, no silent fallback)
- Per-server page: live CPU/RAM/network, console, file manager, snapshots, reinstall, root password reset
- Access over **SSH** (Pinggy tunnel) or a browser terminal (**sshx**), no port forwarding needed
- LXC advanced options: nesting, autostart, swap, CPU priority, process limit, automatic daily snapshots
- One-click installs (Python, Node, Nginx, Git, Docker and more)
- XP, levels, badges, daily rewards and a leaderboard. Coins can extend a server's life
- 5 themes with a live switcher, and an animated tutorial
- REST API with tokens and an in-panel API tester

**For admins** (separate admin console)
- Nodes: add capacity from other servers, set slots, test, enable or disable
- Users and servers: suspend, resize, transfer, grant bonus invites, view activity
- Security: password rules, lockout limits, session length, automatic IP bans, admin IP allowlist, require 2FA, sign out everyone
- Maintenance mode, server lifetime, Discord webhook alerts (raids, crypto mining, new admin device)
- CSV export, global activity log

**Discord bot**
`/invites` `/myservers` `/plans` `/leaderboard` `/status` `/help` and `/nodes` (staff only). It counts only genuine invites, flags raids, and watches for crypto-mining behaviour.

**Security**
scrypt password hashing, CSRF protection, strict CSP and security headers, per-IP and per-account rate limits, honeypot and minimum-fill-time on login forms, optional Cloudflare Turnstile, TOTP 2FA with recovery codes, browser-bound sessions, encrypted stored secrets, signed and replay-protected node API.

---

## Requirements

| | |
|---|---|
| OS | Ubuntu 22.04 / 24.04 or Debian 12, `x86_64` or `aarch64` |
| Access | root |
| Virtualization | A **KVM/full-virtualization** VPS or bare metal (OpenVZ is not supported). `/dev/kvm` is needed for VMs only |
| RAM / disk | 2 GB RAM and 20 GB disk recommended (the installer adds swap on small servers) |
| Domain | A domain on Cloudflare (for the tunnel) |
| Discord | An application with a bot, in your own server |

---

## Install (one command)

Push `install.sh` and `get.sh` to your GitHub repo, set your username in both files (`REPO_RAW` in `get.sh`, `UPDATE_URL` in `install.sh`), then on a fresh server:

```bash
curl -fsSL https://raw.githubusercontent.com/ArizNodesOp/ariznodes-hvm/main/get.sh | sudo bash
```

Or run the file directly:

```bash
sudo bash install.sh
```

The installer asks which type to install:

1. **Normal installation**: web panel + Discord bot + API portal.
2. **API node installation**: adds capacity to an existing panel. It asks for the panel URL and an **admin API token**, verifies it, then registers itself. Run it with `--node` to skip the question.

If it fails or you interrupt it, run it again. Finished steps are skipped and your answers are remembered.

### What you need ready

- Discord bot token, client ID, client secret and server (guild) ID
- Domain (for example `panel.example.com`)
- Cloudflare Tunnel token (Zero Trust → Networks → Tunnels)
- Optional: Cloudflare Turnstile site and secret keys

---

## Configure after installing

1. **Cloudflare tunnel:** add a public hostname for your domain pointing to **HTTP** `localhost:8080` (API nodes: `localhost:8081`).
2. **Discord Developer Portal:**
   - OAuth2 → Redirects: `https://YOUR-DOMAIN/discord/callback`
   - Bot → enable **Server Members Intent**
   - Invite the bot with the **Manage Server** permission
3. Log in as `admin` (the password is printed once at the end of the install), then:
   - Account → change your password and turn on 2FA
   - Admin → Security → set your login rules
   - Admin → Tools → set server lifetime and an alert webhook if you like

---

## Commands

```bash
sudo bash install.sh <command>      # or: sudo ariznodes <command>  after installing
```

| Command | What it does |
|---|---|
| `install` | Full install (default) |
| `upgrade` | Re-deploy panel code, keep data and secrets |
| `self-update` | Download the newest installer from your GitHub URL, then upgrade |
| `status` / `doctor` | Quick health / detailed diagnostics |
| `logs` | Follow web and bot logs |
| `backup` / `restore <file>` | Backups (also automatic daily at 03:30, 14 kept) |
| `reset-admin [user]` | New random password for an account |
| `diag` | Support bundle written to `/root` (no secrets) |
| `node-test` | On an API node: find out why it does not connect |
| `uninstall` | Remove the panel (asks before touching servers) |

Flags: `-y/--yes` (no questions), `--docker-only`, `--harden` / `--no-harden`, `--no-tunnel`, `--port N`, `--domain D`, `--node`, `--config FILE`.

---

## Using the API

Create a token in **Account → API tokens**, or use the **API** page to try requests in the browser.

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" https://YOUR-DOMAIN/api/v1/vps
curl -X POST -H "Authorization: Bearer YOUR_TOKEN" https://YOUR-DOMAIN/api/v1/vps/ID/restart
```

| Endpoint | Purpose |
|---|---|
| `GET /api/v1/ping` | Check a token (admin tokens also return `admin: true`) |
| `GET /api/v1/vps` | List your servers |
| `GET /api/v1/vps/ID/stats` | CPU, memory, network |
| `POST /api/v1/vps/ID/start\|stop\|restart` | Power control |

---

## Multi-node setup

1. On the main panel create an **admin** API token (Account → API tokens).
2. On the second server run the installer and choose **API node**. Give it a tunnel hostname that points to `http://localhost:8081`.
3. The node appears under **Admin → Nodes**. New servers go to the local host first, then to the node with the most free slots.

The node agent accepts only signed `lxc` and `docker` commands and rejects replayed requests.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| "Another package job holds the apt lock" | The installer takes over automatically. If it still stalls, run `ps aux \| grep -E 'apt\|dpkg'` |
| Installer killed or the server froze | Low memory. Re-run. Swap is added automatically |
| Discord "Invalid OAuth2 redirect_uri" | The redirect in the Developer Portal must exactly match `https://YOUR-DOMAIN/discord/callback` |
| Node will not register | Run `sudo bash install.sh node-test`. Usually the tunnel hostname or Cloudflare WAF / Bot Fight Mode |
| Forgot admin password | `sudo bash install.sh reset-admin` |
| Something else | `sudo bash install.sh diag` and share the file |

Install log: `/var/log/ariznodes-install.log`. Service logs: `journalctl -u ariznodes-web -u ariznodes-bot -f`.

---

## Layout on the server

```
/opt/ariznodes/    app code, venv, database (data/panel.db), .env (mode 600)
/etc/ariznodes/    saved install answers and step state
/var/backups/ariznodes/   automatic backups
```

Services: `ariznodes-web` (port 8080, loopback only), `ariznodes-bot`, `ariznodes-agent` (API nodes, port 8081).

---

## License

Proprietary. © 2026 Ariznodes™. All rights reserved. See [LICENSE](LICENSE).
