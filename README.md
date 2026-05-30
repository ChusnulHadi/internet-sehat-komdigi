# internet-sehat DNS Ecosystem

DNS filtering appliance berbasis **dnsdist** yang memblokir domain sesuai blocklist Komdigi/TrustPositif via RPZ. Ditujukan untuk RT-RW Net / ISP kecil.

## Cara Install (install.sh)

### Prasyarat

- Ubuntu 22.04 atau 24.04
- Akses root (`sudo`)
- Server dapat menjangkau IP RPZ Komdigi (koordinasi dengan Komdigi untuk whitelist IP server Anda)

### Langkah 1 — Clone repository

```bash
git clone https://github.com/ChusnulHadi/internet-sehat-komdigi.git
cd internet-sehat-komdigi/
```

### Langkah 2 — Jalankan installer

```bash
sudo bash install.sh
```

Installer akan membuka wizard berbasis teks (whiptail) dengan 6 langkah:

| Langkah | Isian |
|---------|-------|
| 1/6 IP Server | IP interface DNS server (atau `0.0.0.0` untuk semua interface) |
| 2/6 RPZ Remote | IP server RPZ Komdigi untuk AXFR/IXFR |
| 3/6 Nama Zona RPZ | Nama zona RPZ (default: `trustpositifkominfo`) |
| 4/6 Block Mode | `nxdomain` (domain diblokir) atau `redirect` (arahkan ke IP tertentu) |
| 5/6 Client ACL | Subnet klien yang boleh query DNS (contoh: `192.168.1.0/24`) |
| 6/6 Dashboard Port | Port web dashboard (default: `3000`) |

Setelah konfirmasi, installer akan menginstal dan mengkonfigurasi:
- **dnsdist** — DNS resolver berkinerja tinggi
- **rpz-sync** — cron sinkronisasi blocklist setiap 6 jam
- **Dashboard** — web UI monitoring di port yang dipilih

### Re-install / Update

Jalankan `sudo bash install.sh` kembali. Konfigurasi lama otomatis dijadikan nilai default — ubah hanya yang perlu.

---

## Auto-Update

Setelah install, sistem akan otomatis mengambil update dari repository setiap **Minggu pukul 03:00**. Update mencakup:
- DNS scripts (`rpz2cdb.py`, `rpz-sync.py`)
- Dashboard (build ulang otomatis jika ada perubahan)

Log update tersimpan di `/var/log/dnsdist/update.log`.

Untuk update manual:

```bash
sudo internet-sehat-update
```

---

## Mengecek Status Setelah Install

```bash
# Status DNS server
systemctl status dnsdist

# Status dashboard
systemctl status internet-sehat-dashboard

# Test blokir domain
bash dns/test.sh

# Buka dashboard
xdg-open http://localhost:3000
```

---

## Arsitektur Singkat

```
Komdigi RPZ ──AXFR/IXFR──► rpz-sync.py (cron tiap 6 jam)
                                │
                           rpz2cdb.py ──► blocklist.cdb
                                │
                             dnsdist :53
                           ┌────┴────┐
                      klien DNS   REST :8083 ──► Dashboard :3000
```

---

## Membuat Paket Installer (untuk pengelola)

> Lewati bagian ini jika Anda hanya ingin menginstal.

```bash
# Build dashboard + kemas jadi zip
bash create-installer.sh [versi]
# Output: internet-sehat-installer-<versi>.zip
```

Zip ini berisi `install.sh`, konfigurasi DNS, dan dashboard hasil build — alternatif distribusi selain git clone.
