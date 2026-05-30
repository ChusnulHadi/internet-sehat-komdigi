#!/usr/bin/env bash
# =============================================================
# install.sh — internet-sehat DNS Ecosystem
# Interactive TUI installer (whiptail)
# Ubuntu 22.04 / 24.04
# =============================================================

set -uo pipefail

TITLE="internet-sehat DNS Ecosystem"

# ── Warna untuk output terminal (non-whiptail) ────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

# ── Flags ─────────────────────────────────────────────────────
REBUILD_DASHBOARD=false
for arg in "$@"; do
  case "$arg" in
    --rebuild-dashboard) REBUILD_DASHBOARD=true ;;
    --help|-h)
      echo "Penggunaan: sudo bash install.sh [--rebuild-dashboard]"
      echo "  --rebuild-dashboard   Hapus build lama dan build ulang dashboard"
      exit 0 ;;
    *) die "Flag tidak dikenal: $arg" ;;
  esac
done

# ── Preflight checks ──────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Jalankan sebagai root: sudo bash install.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/dns/dnsdist.conf" ]] || \
  die "Jalankan dari root project (direktori yang berisi dns/dnsdist.conf)"

# Deteksi sumber dashboard:
#   zip installer  → dashboard/server.js (standalone sudah di-flatten oleh create-installer.sh)
#   git clone      → dashboard/.next/standalone/server.js (perlu build dulu)
DASHBOARD_SRC=""
if $REBUILD_DASHBOARD; then
  ok "--rebuild-dashboard: akan jalankan npm run build ulang"
elif [[ -f "$SCRIPT_DIR/dashboard/server.js" ]]; then
  DASHBOARD_SRC="$SCRIPT_DIR/dashboard"
elif [[ -f "$SCRIPT_DIR/dashboard/.next/standalone/server.js" ]]; then
  DASHBOARD_SRC="$SCRIPT_DIR/dashboard/.next/standalone"
elif [[ ! -d "$SCRIPT_DIR/dashboard" ]]; then
  die "Direktori dashboard tidak ditemukan"
fi
# Kalau DASHBOARD_SRC masih kosong, dashboard akan di-build saat instalasi

command -v whiptail &>/dev/null || die "whiptail tidak ditemukan. Install: apt-get install whiptail"

# ── Baca konfigurasi yang sudah ada (untuk re-install) ────────
DEF_LISTEN_IP="0.0.0.0"
DEF_RPZ_REMOTE=""
DEF_RPZ_ZONE="trustpositifkominfo"
DEF_BLOCK_MODE="nxdomain"
DEF_REDIRECT_IP="0.0.0.0"
DEF_CLIENT_ACL="0.0.0.0/0"
DEF_DASHBOARD_PORT="3000"
IS_REINSTALL=false

_CONF="/etc/dnsdist/dnsdist.conf"
_CRON="/etc/cron.d/rpz-sync"
_SVC="/etc/systemd/system/internet-sehat-dashboard.service"

if [[ -f "$_CONF" ]] && grep -q "internet-sehat" "$_CONF" 2>/dev/null; then
  IS_REINSTALL=true
  _v=$(grep -oP '^local LISTEN_ADDR\s*=\s*"\K[^"]+' "$_CONF" 2>/dev/null || true)
  [[ -n "$_v" ]] && DEF_LISTEN_IP="$_v"
  _v=$(grep -oP '^local BLOCK_MODE\s*=\s*"\K[^"]+' "$_CONF" 2>/dev/null || true)
  [[ -n "$_v" ]] && DEF_BLOCK_MODE="$_v"
  _v=$(grep -oP '^local REDIRECT_IP\s*=\s*"\K[^"]+' "$_CONF" 2>/dev/null || true)
  [[ -n "$_v" ]] && DEF_REDIRECT_IP="$_v"
  _v=$(grep -oP '^local CLIENT_ACL\s*=\s*\{\s*"\K[^"]+' "$_CONF" 2>/dev/null || true)
  [[ -n "$_v" ]] && DEF_CLIENT_ACL="$_v"
fi

if [[ -f "$_CRON" ]]; then
  _v=$(grep -oP -- '--server \K\S+' "$_CRON" 2>/dev/null | head -1 || true)
  [[ -n "$_v" ]] && DEF_RPZ_REMOTE="$_v"
  _v=$(grep -oP -- '--zone \K\S+' "$_CRON" 2>/dev/null | head -1 || true)
  [[ -n "$_v" ]] && DEF_RPZ_ZONE="$_v"
fi

if [[ -f "$_SVC" ]]; then
  _v=$(grep -oP '^Environment=PORT=\K\d+' "$_SVC" 2>/dev/null || true)
  [[ -n "$_v" ]] && DEF_DASHBOARD_PORT="$_v"
fi

# ── whiptail helpers ──────────────────────────────────────────
# Semua helper redirect stderr→stdout supaya output bisa di-capture

wt_msg() {
  # wt_msg "title" "message" [height]
  whiptail --title "$TITLE — $1" --msgbox "$2" "${3:-14}" 72
}

wt_input() {
  # wt_input "title" "prompt" "default" → stdout = value, exit 1 = cancel
  whiptail --title "$TITLE — $1" \
    --inputbox "$2" 10 72 "$3" \
    3>&1 1>&2 2>&3
}

wt_menu() {
  # wt_menu "title" "prompt" item desc [item desc ...] → stdout = selected
  local title="$1" prompt="$2"; shift 2
  whiptail --title "$TITLE — $1" \
    --menu "$prompt" 16 72 8 "$@" \
    3>&1 1>&2 2>&3
}

wt_yesno() {
  # wt_yesno "title" "message" → 0=yes 1=no
  whiptail --title "$TITLE — $1" --yesno "$2" 14 72
}

cancelled() {
  wt_msg "Dibatalkan" "Instalasi dibatalkan.\n\nJalankan kembali kapan saja:\n  sudo bash install.sh"
  exit 0
}

# ── Welcome ───────────────────────────────────────────────────
if $IS_REINSTALL; then
  _REINSTALL_NOTE="

⟳ Konfigurasi sebelumnya ditemukan — nilai lama akan
  digunakan sebagai default. Ubah jika perlu."
else
  _REINSTALL_NOTE=""
fi

whiptail --title "$TITLE" \
  --msgbox "\
Selamat datang di installer internet-sehat DNS Ecosystem.

Wizard ini akan membantu Anda mengkonfigurasi:

  • dnsdist  — DNS server berkinerja tinggi
  • RPZ      — Blocklist domain dari Komdigi
  • Cron     — Sinkronisasi otomatis setiap 6 jam

Pastikan server ini sudah dapat menjangkau server
RPZ Komdigi sebelum melanjutkan.${_REINSTALL_NOTE}

Tekan Enter / OK untuk memulai." 20 72

# ─────────────────────────────────────────────────────────────
# STEP 1 — IP SERVER (listen address)
# ─────────────────────────────────────────────────────────────
while true; do
  LISTEN_IP=$(wt_input \
    "1/6  IP Server" \
    "IP address interface yang digunakan server ini untuk
menerima query DNS.

Gunakan  0.0.0.0  agar listen di semua interface,
atau IP spesifik jika server punya banyak interface
(contoh: 192.168.1.10)." \
    "$DEF_LISTEN_IP") || cancelled

  [[ -n "$LISTEN_IP" ]] && break
  wt_msg "1/6  IP Server" "IP tidak boleh kosong. Coba lagi."
done

# ─────────────────────────────────────────────────────────────
# STEP 2 — RPZ REMOTE SERVER
# ─────────────────────────────────────────────────────────────
while true; do
  RPZ_REMOTE=$(wt_input \
    "2/6  RPZ Remote Server" \
    "IP address server RPZ Komdigi.

Server ini digunakan untuk AXFR (download awal) dan
IXFR (update incremental) zona blocklist.

Pastikan IP ini sudah di-whitelist di sisi Komdigi." \
    "$DEF_RPZ_REMOTE") || cancelled

  [[ -n "$RPZ_REMOTE" ]] && break
  wt_msg "2/6  RPZ Remote Server" "IP RPZ remote tidak boleh kosong. Coba lagi."
done

# ─────────────────────────────────────────────────────────────
# STEP 3 — ZONE NAME
# ─────────────────────────────────────────────────────────────
while true; do
  RPZ_ZONE=$(wt_input \
    "3/6  Nama Zona RPZ" \
    "Nama zona RPZ yang akan di-transfer dari server Komdigi.

Nama zona ini biasanya sudah ditentukan oleh Komdigi.
Default yang umum digunakan adalah trustpositifkominfo." \
    "$DEF_RPZ_ZONE") || cancelled

  [[ -n "$RPZ_ZONE" ]] && break
  wt_msg "3/6  Nama Zona RPZ" "Nama zona tidak boleh kosong. Coba lagi."
done

# ─────────────────────────────────────────────────────────────
# STEP 4 — BLOCK MODE
# ─────────────────────────────────────────────────────────────
BLOCK_MODE=$(wt_menu \
  "4/6  Mode Blokir" \
  "Pilih cara server merespons query domain yang diblokir.
(Saat ini: ${DEF_BLOCK_MODE})" \
  "nxdomain" "NXDOMAIN  — domain seolah tidak ada (direkomendasikan)" \
  "redirect"  "Redirect  — arahkan ke halaman pemberitahuan blokir" \
  ) || cancelled

REDIRECT_IP="0.0.0.0"
if [[ "$BLOCK_MODE" == "redirect" ]]; then
  while true; do
    REDIRECT_IP=$(wt_input \
      "4/6  Redirect IP" \
      "IP address webserver yang menampilkan halaman blokir.

Semua domain yang diblokir akan diarahkan ke IP ini.
Pastikan webserver sudah berjalan di IP tersebut." \
      "$DEF_REDIRECT_IP") || cancelled

    [[ -n "$REDIRECT_IP" ]] && break
    wt_msg "4/6  Redirect IP" "Redirect IP tidak boleh kosong untuk mode redirect. Coba lagi."
  done
fi

# ─────────────────────────────────────────────────────────────
# STEP 5 — CLIENT ACL
# ─────────────────────────────────────────────────────────────
CLIENT_ACL=$(wt_input \
  "5/6  Client ACL" \
  "CIDR yang diizinkan melakukan query ke server DNS ini.

Contoh:
  0.0.0.0/0        → semua client (publik)
  192.168.1.0/24   → hanya subnet LAN
  10.0.0.0/8       → hanya jaringan internal" \
  "$DEF_CLIENT_ACL") || cancelled

CLIENT_ACL="${CLIENT_ACL:-0.0.0.0/0}"

# ─────────────────────────────────────────────────────────────
# STEP 6 — DASHBOARD PORT
# ─────────────────────────────────────────────────────────────
while true; do
  DASHBOARD_PORT=$(wt_input \
    "6/6  Dashboard Port" \
    "Port HTTP untuk web dashboard monitoring.

Dashboard dapat diakses di http://<IP-server>:<port>
setelah instalasi selesai." \
    "$DEF_DASHBOARD_PORT") || cancelled

  [[ "$DASHBOARD_PORT" =~ ^[0-9]+$ ]] && \
    [[ "$DASHBOARD_PORT" -ge 1 ]] && \
    [[ "$DASHBOARD_PORT" -le 65535 ]] && break
  wt_msg "6/6  Dashboard Port" "Port tidak valid. Masukkan angka antara 1–65535."
done

# ─────────────────────────────────────────────────────────────
# KONFIRMASI
# ─────────────────────────────────────────────────────────────
REDIRECT_LINE=""
[[ "$BLOCK_MODE" == "redirect" ]] && REDIRECT_LINE="\n  Redirect IP   : $REDIRECT_IP"

wt_yesno "Konfirmasi" "\
Ringkasan konfigurasi:

  Listen IP     : $LISTEN_IP
  RPZ Remote    : $RPZ_REMOTE
  Nama Zona     : $RPZ_ZONE
  Mode Blokir   : $BLOCK_MODE${REDIRECT_LINE}
  Client ACL    : $CLIENT_ACL
  Dashboard Port: $DASHBOARD_PORT

Lanjutkan instalasi dengan konfigurasi di atas?" || cancelled

# ─────────────────────────────────────────────────────────────
# INSTALASI
# ─────────────────────────────────────────────────────────────
TMPKEY=$(mktemp)
TMPAPIKEY=$(mktemp)
TMPSYNC=$(mktemp)
TMPPORT=$(mktemp)
TMPERR=$(mktemp)
cleanup() { rm -f "$TMPKEY" "$TMPAPIKEY" "$TMPSYNC" "$TMPPORT" "$TMPERR"; }
trap cleanup EXIT

(
  # Format gauge: angka saja = update persen
  # XXX / angka / teks / XXX = update persen + teks

  # ── 1. Dependencies ──
  echo "XXX"; echo "5"; echo "Menginstall dependencies (apt-get)..."; echo "XXX"
  if ! apt-get update -qq 2>>"$TMPERR" \
     || ! apt-get install -y dnsdist freecdb python3 dnsutils curl git -qq 2>>"$TMPERR"; then
    echo "INSTALL_FAILED" > "$TMPSYNC"
  fi
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >>"$TMPERR" 2>&1
  apt-get install -y nodejs -qq 2>>"$TMPERR"

  # ── 2. Direktori ──
  echo "XXX"; echo "20"; echo "Menyiapkan direktori sistem..."; echo "XXX"
  mkdir -p /etc/dnsdist /opt/blocklist /var/log/dnsdist /opt/dashboard

  # ── 3. Copy files ──
  echo "XXX"; echo "28"; echo "Mengcopy konfigurasi dan scripts..."; echo "XXX"
  LIB_DIR="/usr/local/lib/internet-sehat"
  mkdir -p "$LIB_DIR"
  cp "$SCRIPT_DIR/dns/dnsdist.conf" /etc/dnsdist/dnsdist.conf
  cp "$SCRIPT_DIR/dns/rpz2cdb.py"  "$LIB_DIR/rpz2cdb.py"
  cp "$SCRIPT_DIR/dns/rpz-sync.py" "$LIB_DIR/rpz-sync.py"
  cp "$SCRIPT_DIR/dns/test.sh"     /usr/local/bin/dns-test
  chmod +x "$LIB_DIR/rpz2cdb.py" "$LIB_DIR/rpz-sync.py" /usr/local/bin/dns-test
  ln -sf "$LIB_DIR/rpz2cdb.py"  /usr/local/bin/rpz2cdb
  ln -sf "$LIB_DIR/rpz-sync.py" /usr/local/bin/rpz-sync

  # ── 3b. Build dashboard jika belum ada atau --rebuild-dashboard ──
  _DASH_SRC="$DASHBOARD_SRC"
  if [[ -z "$_DASH_SRC" ]]; then
    if ! $REBUILD_DASHBOARD; then
      echo "XXX"; echo "32"; echo "Build dashboard (npm ci)..."; echo "XXX"
      (cd "$SCRIPT_DIR/dashboard" && npm ci --prefer-offline 2>>"$TMPERR") || \
      (cd "$SCRIPT_DIR/dashboard" && npm ci 2>>"$TMPERR") || \
        { echo "INSTALL_FAILED" > "$TMPSYNC"; }
    fi

    echo "XXX"; echo "36"; echo "Build dashboard (npm run build) — ini beberapa menit..."; echo "XXX"
    (cd "$SCRIPT_DIR/dashboard" && npm run build 2>>"$TMPERR") || \
      { echo "INSTALL_FAILED" > "$TMPSYNC"; }

    _DASH_SRC="$SCRIPT_DIR/dashboard/.next/standalone"
  fi

  echo "XXX"; echo "40"; echo "Mengcopy dashboard..."; echo "XXX"
  cp -r "$_DASH_SRC/." /opt/dashboard/

  # Kalau dari standalone (git clone), static dan public tidak ikut di standalone dir
  if [[ "$_DASH_SRC" == *"standalone"* ]]; then
    mkdir -p /opt/dashboard/.next
    [[ -d "$SCRIPT_DIR/dashboard/.next/static" ]] && \
      cp -r "$SCRIPT_DIR/dashboard/.next/static" /opt/dashboard/.next/static
    [[ -d "$SCRIPT_DIR/dashboard/public" ]] && \
      cp -r "$SCRIPT_DIR/dashboard/public"       /opt/dashboard/public
  fi

  # ── 4. Konfigurasi dnsdist.conf ──
  echo "XXX"; echo "48"; echo "Menulis konfigurasi dnsdist..."; echo "XXX"
  CONSOLE_KEY=$(python3 -c \
    "import secrets,base64; print(base64.b64encode(secrets.token_bytes(32)).decode())")
  echo "$CONSOLE_KEY" > "$TMPKEY"

  DASHBOARD_KEY=$(python3 -c "import secrets; print(secrets.token_hex(24))")
  echo "$DASHBOARD_KEY" > "$TMPAPIKEY"

  CONF="/etc/dnsdist/dnsdist.conf"
  sed -i "s|^local LISTEN_ADDR\s*=.*|local LISTEN_ADDR   = \"${LISTEN_IP}\"|"              "$CONF"
  sed -i "s|^local BLOCK_MODE\s*=.*|local BLOCK_MODE    = \"${BLOCK_MODE}\"|"              "$CONF"
  sed -i "s|^local REDIRECT_IP\s*=.*|local REDIRECT_IP   = \"${REDIRECT_IP}\"|"            "$CONF"
  sed -i "s|^local CLIENT_ACL\s*=.*|local CLIENT_ACL    = { \"${CLIENT_ACL}\", \"::/0\" }|" "$CONF"
  sed -i "s|^-- setKey.*|setKey(\"${CONSOLE_KEY}\")|"                                      "$CONF"
  sed -i "s|^local DASHBOARD_API_KEY\s*=.*|local DASHBOARD_API_KEY  = \"${DASHBOARD_KEY}\"|" "$CONF"

  # ── 5. Cek port 53 ──
  echo "XXX"; echo "52"; echo "Memeriksa ketersediaan port 53..."; echo "XXX"
  if ss -ulnp 2>/dev/null | grep -q ':53 ' || ss -tlnp 2>/dev/null | grep -q ':53 '; then
    echo "busy" > "$TMPPORT"
  else
    echo "free" > "$TMPPORT"
  fi

  # ── 6. Sinkronisasi zona (AXFR/IXFR) ──
  if [[ -s /opt/blocklist/blocklist.cdb ]]; then
    echo "XXX"; echo "55"
    echo "Blocklist ada — sinkronisasi incremental (IXFR)..."
    echo "dari $RPZ_REMOTE"
    echo "XXX"
    _SYNC_FLAGS=""
  else
    echo "XXX"; echo "55"
    echo "Blocklist kosong — download penuh (AXFR) dari $RPZ_REMOTE..."
    echo "(ini bisa memakan waktu beberapa menit)"
    echo "XXX"
    _SYNC_FLAGS="--force"
  fi
  if rpz-sync --server "$RPZ_REMOTE" --zone "$RPZ_ZONE" $_SYNC_FLAGS \
       >> /var/log/dnsdist/rpz-sync.log 2>&1; then
    echo "ok" > "$TMPSYNC"
  else
    echo "fail" > "$TMPSYNC"
  fi

  # ── 7. Service ──
  echo "XXX"; echo "80"; echo "Mengaktifkan dan memulai dnsdist service..."; echo "XXX"
  systemctl enable dnsdist 2>/dev/null || true
  systemctl restart dnsdist
  sleep 2

  # ── 7b. Dashboard service ──
  echo "XXX"; echo "85"; echo "Menyiapkan dashboard service..."; echo "XXX"
  cat > /etc/systemd/system/internet-sehat-dashboard.service << SVCEOF
[Unit]
Description=internet-sehat DNS Dashboard
After=network.target

[Service]
Type=simple
Environment=PORT=${DASHBOARD_PORT}
Environment=HOSTNAME=0.0.0.0
Environment=DNSDIST_URL=http://127.0.0.1:8083
Environment=DNSDIST_API_KEY=${DASHBOARD_KEY}
Restart=on-failure
RestartSec=5
ExecStart=/usr/bin/node /opt/dashboard/server.js

[Install]
WantedBy=multi-user.target
SVCEOF
  systemctl daemon-reload
  systemctl enable internet-sehat-dashboard 2>/dev/null || true
  systemctl restart internet-sehat-dashboard

  # ── 8. Cron ──
  echo "XXX"; echo "88"; echo "Mengatur jadwal sinkronisasi otomatis (cron)..."; echo "XXX"
  cat > /etc/cron.d/rpz-sync <<CRONEOF
# internet-sehat — sync blocklist dari Komdigi (setiap 6 jam)
0 */6 * * * root /usr/local/bin/rpz-sync --server ${RPZ_REMOTE} --zone ${RPZ_ZONE} >> /var/log/dnsdist/rpz-sync.log 2>&1
CRONEOF
  chmod 644 /etc/cron.d/rpz-sync

  # ── 8b. Auto-update script & cron ──
  echo "XXX"; echo "93"; echo "Menginstall skrip auto-update..."; echo "XXX"
  cat > /usr/local/bin/internet-sehat-update <<UPDATEEOF
#!/bin/bash
exec bash "${SCRIPT_DIR}/update.sh" "\$@"
UPDATEEOF
  chmod +x /usr/local/bin/internet-sehat-update

  cat > /etc/cron.d/internet-sehat-update <<CRONEOF
# internet-sehat — auto-update dari repository (setiap Minggu jam 03:00)
0 3 * * 0 root /usr/local/bin/internet-sehat-update >> /var/log/dnsdist/update.log 2>&1
CRONEOF
  chmod 644 /etc/cron.d/internet-sehat-update

  # ── 9. DNS test ──
  echo "XXX"; echo "96"; echo "Menjalankan tes DNS..."; echo "XXX"
  dns-test 127.0.0.1 53 > /var/log/dnsdist/install-test.log 2>&1 || true

  echo "100"

) | whiptail --title "$TITLE — Instalasi" \
    --gauge "Mempersiapkan instalasi..." 8 72 0

# ─────────────────────────────────────────────────────────────
# HASIL
# ─────────────────────────────────────────────────────────────
CONSOLE_KEY=$(cat "$TMPKEY" 2>/dev/null || echo "(tidak tersedia)")
DASHBOARD_KEY=$(cat "$TMPAPIKEY" 2>/dev/null || echo "(tidak tersedia)")
SYNC_STATUS=$(cat "$TMPSYNC" 2>/dev/null || echo "fail")
PORT_STATUS=$(cat "$TMPPORT" 2>/dev/null || echo "free")

if systemctl is-active --quiet dnsdist; then
  SVC_STATUS="Berjalan ✓"
else
  SVC_STATUS="GAGAL START ✗"
fi

if systemctl is-active --quiet internet-sehat-dashboard; then
  DASH_STATUS="Berjalan ✓  → http://${LISTEN_IP}:${DASHBOARD_PORT}"
else
  DASH_STATUS="GAGAL START ✗"
fi

# Bangun pesan hasil
RESULT_MSG="Instalasi selesai!\n\n"
RESULT_MSG+="  Listen IP     : ${LISTEN_IP}:53\n"
RESULT_MSG+="  RPZ Remote    : ${RPZ_REMOTE}\n"
RESULT_MSG+="  Zona          : ${RPZ_ZONE}\n"
RESULT_MSG+="  Mode Blokir   : ${BLOCK_MODE}\n"
RESULT_MSG+="  dnsdist       : ${SVC_STATUS}\n"
RESULT_MSG+="  Dashboard     : ${DASH_STATUS}\n"
RESULT_MSG+="\n"
RESULT_MSG+="  Auto-update   : Setiap Minggu 03:00 WIB\n"
RESULT_MSG+="\n"
RESULT_MSG+="Console key (simpan ini!):\n  ${CONSOLE_KEY}\n"
RESULT_MSG+="\n"
RESULT_MSG+="Akses CLI:\n  dnsdist --client -k \"${CONSOLE_KEY}\"\n"
RESULT_MSG+="\n"
RESULT_MSG+="Update manual: sudo internet-sehat-update\n"

# Peringatan
WARNINGS=""
if [[ "$PORT_STATUS" == "busy" ]]; then
  WARNINGS+="\n⚠  Port 53 sudah dipakai oleh proses lain."
  WARNINGS+="\n   Jika systemd-resolved: tambahkan DNSStubListener=no"
  WARNINGS+="\n   di /etc/systemd/resolved.conf lalu restart."
fi
if [[ "$SYNC_STATUS" == "fail" ]]; then
  WARNINGS+="\n\n⚠  Sinkronisasi zona RPZ gagal."
  WARNINGS+="\n   Blocklist belum aktif. Retry setelah koneksi tersedia:"
  WARNINGS+="\n   rpz-sync --server ${RPZ_REMOTE} --zone ${RPZ_ZONE} --force"
fi
if ! systemctl is-active --quiet dnsdist; then
  WARNINGS+="\n\n✗  dnsdist gagal start. Cek log:"
  WARNINGS+="\n   journalctl -u dnsdist -n 30 --no-pager"
fi

[[ -n "$WARNINGS" ]] && RESULT_MSG+="\nPeringatan:${WARNINGS}"

wt_msg "Selesai" "$RESULT_MSG" 28
