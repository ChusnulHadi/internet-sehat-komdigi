#!/usr/bin/env bash
# update.sh — Auto-update internet-sehat dari repository
set -uo pipefail

LOG=/var/log/dnsdist/update.log
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
ok()   { log "[OK]    $*"; }
err()  { log "[ERROR] $*"; }

[[ $EUID -eq 0 ]] || { echo "Jalankan sebagai root: sudo internet-sehat-update"; exit 1; }

command -v git &>/dev/null || { err "git tidak ditemukan. Install: apt-get install git"; exit 1; }

[[ -d "$SCRIPT_DIR/.git" ]] || { err "$SCRIPT_DIR bukan git repository"; exit 1; }

cd "$SCRIPT_DIR"

log "=== Memulai update internet-sehat ==="
log "Repository: $SCRIPT_DIR"

# ── 1. git pull ───────────────────────────────────────────────
log "Mengambil update dari repository..."
BEFORE=$(git rev-parse HEAD)
if ! git pull --ff-only >> "$LOG" 2>&1; then
  err "git pull gagal — cek koneksi atau ada local changes yang belum di-commit"
  exit 1
fi
AFTER=$(git rev-parse HEAD)

if [[ "$BEFORE" == "$AFTER" ]]; then
  log "Tidak ada update baru."
  log "=== Selesai (tidak ada perubahan) ==="
  exit 0
fi

log "Update: ${BEFORE:0:8} → ${AFTER:0:8}"
git log --oneline "$BEFORE..$AFTER" | while read -r line; do log "  * $line"; done

# ── 2. Deteksi file yang berubah ──────────────────────────────
CHANGED=$(git diff --name-only "$BEFORE" "$AFTER")
DNS_CHANGED=false
DASH_CHANGED=false

echo "$CHANGED" | grep -qE '^dns/(rpz2cdb|rpz-sync|test)' && DNS_CHANGED=true
echo "$CHANGED" | grep -q '^dashboard/'                    && DASH_CHANGED=true

# ── 3. Update DNS scripts ─────────────────────────────────────
if $DNS_CHANGED; then
  LIB_DIR="/usr/local/lib/internet-sehat"
  log "Update DNS scripts..."
  cp dns/rpz2cdb.py  "$LIB_DIR/rpz2cdb.py"
  cp dns/rpz-sync.py "$LIB_DIR/rpz-sync.py"
  cp dns/test.sh     /usr/local/bin/dns-test
  chmod +x "$LIB_DIR/rpz2cdb.py" "$LIB_DIR/rpz-sync.py" /usr/local/bin/dns-test
  ok "DNS scripts di-update (cron akan pakai versi baru pada jadwal berikutnya)"
else
  log "DNS scripts tidak berubah — skip"
fi

# ── 4. Update & build dashboard ───────────────────────────────
if $DASH_CHANGED; then
  log "Dashboard berubah — build ulang (ini bisa beberapa menit)..."
  if ! (cd dashboard && npm ci --prefer-offline >> "$LOG" 2>&1 && npm run build >> "$LOG" 2>&1); then
    err "Build dashboard gagal — lihat $LOG untuk detail"
    exit 1
  fi
  STANDALONE="dashboard/.next/standalone"
  if [[ ! -d "$STANDALONE" ]]; then
    err "Standalone output tidak ditemukan: $STANDALONE"
    exit 1
  fi
  cp -r "$STANDALONE/." /opt/dashboard/
  systemctl restart internet-sehat-dashboard
  ok "Dashboard di-update dan di-restart"
else
  log "Dashboard tidak berubah — skip"
fi

log "=== Update selesai ==="
