#!/bin/bash
set -uo pipefail

log() { echo "[entrypoint] $*"; }

# ── Cron untuk rpz-sync terjadwal ────────────────────────────────
cron 2>/dev/null || true

# ── Dashboard (Next.js standalone) ───────────────────────────────
start_dashboard() {
  kill "${DASHBOARD_PID:-}" 2>/dev/null || true
  PORT=3000 HOSTNAME=0.0.0.0 node /opt/dashboard/server.js &
  DASHBOARD_PID=$!
  log "dashboard started (pid $DASHBOARD_PID)"
}

DASHBOARD_PID=""
start_dashboard

# ── Auto-configure via env vars ───────────────────────────────────
# Jika DNSDIST_RPZ_REMOTE di-set, setup dan start dnsdist tanpa install.sh
if [ -n "${DNSDIST_RPZ_REMOTE:-}" ] && ! grep -q "internet-sehat" /etc/dnsdist/dnsdist.conf 2>/dev/null; then
  log "Env DNSDIST_RPZ_REMOTE ditemukan, setup otomatis..."

  cp /opt/internet-sehat/dns/dnsdist.conf /etc/dnsdist/dnsdist.conf

  log "Sinkronisasi blocklist awal dari ${DNSDIST_RPZ_REMOTE}..."
  rpz-sync \
    --server "$DNSDIST_RPZ_REMOTE" \
    --zone   "${DNSDIST_RPZ_ZONE:-trustpositifkominfo}" \
    --force 2>&1 | while IFS= read -r line; do log "$line"; done \
    || log "WARN: sync awal gagal, dnsdist tetap start tanpa blocklist"
fi

# ── Info ──────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║       internet-sehat DNS container           ║"
echo "║                                              ║"
echo "║  Dashboard : http://localhost:3000           ║"
if [ -f /etc/dnsdist/dnsdist.conf ]; then
echo "║  DNS       : port 53 (aktif)                 ║"
else
echo "║  DNS       : port 53 (belum dikonfigurasi)   ║"
echo "║                                              ║"
echo "║  Instalasi manual:                           ║"
echo "║  docker exec -it <container> \\               ║"
echo "║    bash /opt/internet-sehat/install.sh       ║"
fi
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Signal handler ────────────────────────────────────────────────
cleanup() {
  log "shutting down..."
  kill "${DNSDIST_PID:-}" "${DASHBOARD_PID:-}" 2>/dev/null || true
  exit 0
}
trap cleanup SIGTERM SIGINT

# ── Watchdog loop ─────────────────────────────────────────────────
DNSDIST_PID=""
LAST_MTIME=0

while true; do
  # Restart dashboard kalau mati
  if [ -n "$DASHBOARD_PID" ] && ! kill -0 "$DASHBOARD_PID" 2>/dev/null; then
    log "dashboard mati, restart..."
    start_dashboard
  fi

  # Deteksi config dnsdist — start/restart saat muncul atau berubah
  if [ -f /etc/dnsdist/dnsdist.conf ]; then
    MTIME=$(stat -c %Y /etc/dnsdist/dnsdist.conf 2>/dev/null || echo 0)

    DNSDIST_DEAD=false
    [ -n "$DNSDIST_PID" ] && ! kill -0 "$DNSDIST_PID" 2>/dev/null && DNSDIST_DEAD=true

    if [ "$MTIME" != "$LAST_MTIME" ] || [ "$DNSDIST_DEAD" = true ]; then
      LAST_MTIME=$MTIME
      kill "${DNSDIST_PID:-}" 2>/dev/null || true
      dnsdist --supervised --disable-syslog -C /etc/dnsdist/dnsdist.conf &
      DNSDIST_PID=$!
      log "dnsdist started (pid $DNSDIST_PID)"
    fi
  fi

  sleep 5
done
