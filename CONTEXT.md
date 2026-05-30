# CONTEXT.md — internet-sehat

> Source of truth. Look up **§Feature Index** first → open only the file it points to. Don't scan from scratch. If code conflicts, code wins → update this file.

## TL;DR
DNS filtering appliance. Blocks domains per Komdigi/TrustPositif RPZ blocklist via **dnsdist**. Syncs blocklist → CDB → serves filtering resolver + monitoring dashboard.
- **Audience:** RT-RW Net / small ISP. **Phase:** active prototype (not production).
- **Canonical deploy:** zip installer (`create-installer.sh` → `install.sh`) on existing Ubuntu/Debian. ISO/Docker/preseed = secondary.
- Comments & UI in Indonesian. Stack: Bash/POSIX sh, Python 3, dnsdist (Lua), Next.js 16.
- Not a git repo yet.

## TOC
[Facts](#facts) · [Architecture](#architecture) · [Directory Map](#directory-map) · [Feature Index](#feature-index) · [DNS Core](#dns-core) · [Installer/ISO](#installeriso) · [Docker](#docker) · [Dashboard](#dashboard) · [Env Vars](#env-vars) · [Commands](#commands) · [Conventions](#conventions) · [TODO/Unfilled](#todo--unfilled)

## Facts
| | |
|---|---|
| Purpose | DNS filter per Komdigi/TrustPositif RPZ |
| Resolver | dnsdist 1.9.x |
| Blocklist src | Komdigi RPZ via AXFR/IXFR — remote `193.255.196.202`, zone `trustpositifkominfo` |
| Blocklist fmt | CDB (built from RPZ), stored `/opt/blocklist` |
| Target OS | Ubuntu 22.04/24.04 (install.sh); Debian Bookworm (ISO); Ubuntu 24.04 (Docker) |
| Dashboard | Next.js 16.2.4 / React 19.2.4 / Tailwind v4 / shadcn `radix-lyra` |
| Ports | DNS 53, dnsdist REST API 8083, dashboard 3000 |

## Architecture
```
Komdigi RPZ ──AXFR/IXFR──► rpz-sync.py (cron)
                               │
                          rpz2cdb.py ──► blocklist.cdb
                               │
                            dnsdist (dnsdist.conf, Lua; env-driven)
                          ┌────┴─────┐
                   clients:53   REST:8083 ──► dashboard :3000 (/api/stats)
```
- **zip (canonical):** `create-installer.sh` (build+zip) → unzip → `sudo bash install.sh` (whiptail TUI) → dnsdist+scripts+cron+dashboard.
- **ISO:** boot → `installer/init` (PID1) → `wizard.sh` → `install-os.sh` (debootstrap Debian) → `config-dns.sh` (chroot) → reboot.
- **Docker:** `docker compose up` → `entrypoint.sh` auto-configures from env.

## Directory Map
| Path | Role |
|---|---|
| `install.sh` | Main whiptail TUI installer (existing host), re-install aware |
| `create-installer.sh` | Build dashboard + package `internet-sehat-installer-<ver>.zip` |
| `build-iso.sh` | Build live ISO (Alpine live + Debian target, BIOS+UEFI) |
| `Dockerfile` / `docker-compose.yml` | Ubuntu 24.04 image: dnsdist + dashboard |
| `dns/dnsdist.conf` | dnsdist config (Lua); reads env, install.sh overwrites lines |
| `dns/rpz-sync.py` | Sync blocklist from Komdigi RPZ (IXFR incremental / AXFR full) |
| `dns/rpz2cdb.py` | RPZ zone → CDB (+ other formats) |
| `dns/build-cdb.sh` | Build CDB from plain domain list |
| `dns/test.sh`, `dns/domains-test.txt` | Resolution/block tests |
| `installer/init` | PID1: storage modules, env, run wizard |
| `installer/wizard.sh` | Whiptail config wizard |
| `installer/install-os.sh` | Silent OS install: partition/debootstrap/GRUB |
| `installer/config-dns.sh` | Configure dnsdist in target chroot |
| `autoinstall/`, `preseed/` | Unattended Debian install + firstboot |
| `docker/` | `entrypoint.sh`, `reload-dashboard.sh`, `systemctl-fake.sh` |
| `dashboard/` | Next.js dashboard (see §Dashboard) |
| `*.iso`, `*.zip`, `*.cdb` | Build artifacts — don't read |

## Feature Index
| Task / want | File |
|---|---|
| DNS block rules, client ACL, block mode | `dns/dnsdist.conf` |
| Blocklist sync from Komdigi (AXFR/IXFR, schedule) | `dns/rpz-sync.py` + cron |
| RPZ → CDB conversion | `dns/rpz2cdb.py`, `dns/build-cdb.sh` |
| Test if domain blocked | `dns/test.sh`, `dns/domains-test.txt` |
| Interactive install (existing host) | `install.sh` |
| Build release zip | `create-installer.sh` |
| Build/modify ISO | `build-iso.sh` |
| ISO first-boot wizard | `installer/wizard.sh`, `installer/init` |
| Partition/debootstrap/GRUB | `installer/install-os.sh` |
| dnsdist config during ISO install | `installer/config-dns.sh` |
| Container / env-driven deploy | `docker-compose.yml`, `docker/entrypoint.sh`, `Dockerfile` |
| Unattended install | `autoinstall/user-data`, `preseed/preseed.cfg` |
| Stats UI / charts | `dashboard/app/page.tsx` |
| Stats endpoint (proxy to dnsdist) | `dashboard/app/api/stats/route.ts` |
| UI components (shadcn) | `dashboard/components/ui/` |
| Env vars + defaults | §Env Vars + `dns/dnsdist.conf` + `docker-compose.yml` |

## DNS Core
`dns/`. `dnsdist.conf` (Lua, 1.9.x): env→default fallback; install.sh overwrites config lines; sets `LISTEN_ADDR`, `CLIENT_ACL`, `BLOCK_MODE` (nxdomain/redirect), `REDIRECT_IP`, REST API `0.0.0.0:8083`. `rpz-sync.py`: cron-scheduled IXFR/AXFR pull. `rpz2cdb.py`: RPZ→CDB. `build-cdb.sh`: CDB from plain list.

## Installer/ISO
- **install.sh** (canonical): root required; whiptail helpers `wt_msg/wt_input/wt_menu/wt_yesno`; re-install aware; installs dnsdist+scripts+cron+dashboard.
- **ISO** (`build-iso.sh`+`installer/`): Alpine live env, Debian Bookworm target; ~80MB ISO / ~800MB installed; BIOS+UEFI; flow `init→wizard.sh→install-os.sh→config-dns.sh→reboot`. Build deps: `grub-pc-bin grub-efi-amd64-bin xorriso mtools curl openssl`.
- **autoinstall/preseed:** unattended install + `firstboot-profile.sh`.

## Docker
Ubuntu 24.04 + dnsdist, freecdb, dnsutils, python3, whiptail, cron, Node 22. `systemctl-fake.sh` lets install.sh run in container. `entrypoint.sh`: cron rpz-sync + dashboard (`node /opt/dashboard/server.js`, PORT 3000) + auto-config from env. compose: exposes 8083+3000, port 53 commented (uncomment for direct); volumes `blocklist`, `logs`.

## Dashboard
`dashboard/` — Next.js 16.2.4 / React 19.2.4 / Tailwind v4 / shadcn `radix-lyra`.
⚠️ Next.js 16 has breaking changes vs training data — **read `dashboard/node_modules/next/dist/docs/` before coding**. See memory `project_nextjs16`.

| File | Role |
|---|---|
| `app/page.tsx` | `"use client"`, recharts, polls stats |
| `app/api/stats/route.ts` | Proxy GET dnsdist `/api/v1/servers/localhost` w/ `X-API-Key`; env `DNSDIST_URL`, `DNSDIST_API_KEY`/`_DASHBOARD_API_KEY` |
| `app/layout.tsx` | Root layout, fonts (Geist, JetBrains Mono) |
| `app/globals.css` | Tailwind v4 `@import "tailwindcss"` |
| `components/ui/` | shadcn: badge, button, card |
| `lib/utils.ts` | `cn()` |

**NJS16 rules:** `params`/`searchParams` are **Promise** → `await`; `@import "tailwindcss"` (not `@tailwind`); unified `radix-ui` pkg; `@phosphor-icons/react` (not lucide); `output: 'standalone'`.

## Env Vars
Defaults in `dns/dnsdist.conf`; prod examples in `docker-compose.yml`.
| Env | Default | Role |
|---|---|---|
| `DNSDIST_LISTEN_ADDR` | `0.0.0.0` | DNS listen addr |
| `DNSDIST_CLIENT_ACL` | `0.0.0.0/0` | Allowed client ACL |
| `DNSDIST_BLOCK_MODE` | `nxdomain` | Block mode (nxdomain/redirect) |
| `DNSDIST_REDIRECT_IP` | `0.0.0.0` | Redirect IP (redirect mode) |
| `DNSDIST_DASHBOARD_LISTEN` | `0.0.0.0:8083` | dnsdist REST listen |
| `DNSDIST_DASHBOARD_PASSWORD` | `changeme` | dnsdist web/console pw |
| `DNSDIST_DASHBOARD_API_KEY` | `changeme` | dnsdist REST API key |
| `DNSDIST_RPZ_REMOTE` | `193.255.196.202` | Komdigi RPZ remote |
| `DNSDIST_RPZ_ZONE` | `trustpositifkominfo` | RPZ zone name |
| `DNSDIST_URL` (dash) | `http://127.0.0.1:8083` | dnsdist endpoint for dashboard |
| `DNSDIST_API_KEY` (dash) | — | API key for `/api/stats` |

⚠️ Defaults = `changeme`. Real secrets go in `.env` (gitignored; see `.env.example`) — never commit. compose interpolates `${DNSDIST_*:-changeme}`.

## Commands
```bash
bash create-installer.sh [ver]        # → internet-sehat-installer-<ver>.zip
sudo bash install.sh                  # install on existing host
bash build-iso.sh                     # → internet-sehat-dns.iso
docker compose up --build
cd dashboard && npm install && npm run dev   # :3000
cd dashboard && npm run build                # standalone
bash dns/test.sh
```

## Conventions
- Comments/output/UI in Indonesian.
- `install.sh`/`build-iso.sh` = bash; `installer/*` = POSIX sh (Alpine/busybox).
- DNS scripts = Python 3, no heavy deps.
- Dashboard: read local NJS16 docs before coding.
- Never read artifacts: `*.iso`, `*.zip`, `*.cdb`, `node_modules/`, `.next/`.

## TODO / Unfilled
Owner to fill (active prototype):
- [ ] Roadmap / next release goal
- [ ] Dashboard functional status (done vs placeholder)
- [ ] Real RT-RW Net topology (resolver placement, client count)
- [ ] Blocklist update strategy (actual cron interval, AXFR-fail fallback)
- [ ] Prod hardening (replace `changeme`, tighten ACL)
- [ ] Versioning/changelog scheme
- [ ] Make it a git repo?

> On adding files/features: update Directory Map + Feature Index here.
