#!/bin/sh
# Konfigurasi dnsdist di dalam target chroot
# Dipanggil dari install-os.sh setelah packages terinstall

set -e
. /tmp/installer.conf

TARGET="/mnt"
LIB_DIR="/usr/local/lib/internet-sehat"
SRC="/installer/dns"

# ── Copy files ────────────────────────────────────────────────
mkdir -p "$TARGET/$LIB_DIR"
mkdir -p "$TARGET/etc/dnsdist"
mkdir -p "$TARGET/opt/blocklist"
mkdir -p "$TARGET/opt/dashboard"
mkdir -p "$TARGET/var/log/dnsdist"

cp "$SRC/rpz2cdb.py"  "$TARGET/$LIB_DIR/"
cp "$SRC/rpz-sync.py" "$TARGET/$LIB_DIR/"
cp "$SRC/test.sh"     "$TARGET/usr/local/bin/dns-test"
chmod +x "$TARGET/$LIB_DIR/"*.py "$TARGET/usr/local/bin/dns-test"

chroot "$TARGET" ln -sf "$LIB_DIR/rpz2cdb.py"  /usr/local/bin/rpz2cdb
chroot "$TARGET" ln -sf "$LIB_DIR/rpz-sync.py" /usr/local/bin/rpz-sync

# Dashboard pre-built standalone
cp -r /installer/dashboard/. "$TARGET/opt/dashboard/"

# ── Tulis dnsdist.conf dengan konfigurasi yang sudah dikumpulkan ──
CONSOLE_KEY=$(openssl rand -base64 32)
DASHBOARD_KEY=$(openssl rand -hex 24)

sed \
    -e "s|^local BLOCK_MODE\s*=.*|local BLOCK_MODE    = \"${BLOCK_MODE}\"|" \
    -e "s|^local REDIRECT_IP\s*=.*|local REDIRECT_IP   = \"${REDIRECT_IP}\"|" \
    -e "s|^-- setKey.*|setKey(\"${CONSOLE_KEY}\")|" \
    -e "s|^local DASHBOARD_API_KEY\s*=.*|local DASHBOARD_API_KEY  = \"${DASHBOARD_KEY}\"|" \
    "$SRC/dnsdist.conf" > "$TARGET/etc/dnsdist/dnsdist.conf"

# Simpan console key ke file untuk referensi admin
echo "$CONSOLE_KEY" > "$TARGET/root/.dnsdist-key"
chmod 600 "$TARGET/root/.dnsdist-key"

# ── Cron: sinkronisasi RPZ setiap 6 jam ──────────────────────
# Dijalankan pelan & hemat resource: nice/ionice menurunkan prioritas
# CPU/IO, systemd-run -p MemoryMax mengurung sync di cgroup sendiri
# (256M longgar — sync fully streaming). Kalau sync membengkak, yang
# kena OOM hanya scope sync, BUKAN dnsdist → DNS tetap jalan.
cat > "$TARGET/etc/cron.d/rpz-sync" << CRONEOF
# internet-sehat — sync blocklist dari Komdigi (low-priority, memory-capped)
0 */6 * * * root systemd-run --scope --quiet --collect -p MemoryMax=256M nice -n 19 ionice -c3 /usr/local/bin/rpz-sync --server ${RPZ_REMOTE} --zone ${RPZ_ZONE} >> /var/log/dnsdist/rpz-sync.log 2>&1
CRONEOF
chmod 644 "$TARGET/etc/cron.d/rpz-sync"

# ── Enable dnsdist service ────────────────────────────────────
chroot "$TARGET" systemctl enable dnsdist 2>/dev/null || true

# ── Dashboard service ─────────────────────────────────────────
cat > "$TARGET/etc/systemd/system/internet-sehat-dashboard.service" << SVCEOF
[Unit]
Description=internet-sehat DNS Dashboard
After=network.target

[Service]
Type=simple
Environment=PORT=3000
Environment=HOSTNAME=0.0.0.0
Environment=DNSDIST_URL=http://127.0.0.1:8083
Environment=DNSDIST_API_KEY=${DASHBOARD_KEY}
Restart=on-failure
RestartSec=5
ExecStart=/usr/bin/node /opt/dashboard/server.js

[Install]
WantedBy=multi-user.target
SVCEOF
chroot "$TARGET" systemctl enable internet-sehat-dashboard 2>/dev/null || true

# ── MOTD — tampilkan info penting saat login ─────────────────
cat > "$TARGET/etc/motd" << MOTDEOF

  ╔══════════════════════════════════════════════╗
  ║       internet-sehat DNS Server              ║
  ╠══════════════════════════════════════════════╣
  ║  RPZ Remote : ${RPZ_REMOTE}
  ║  Zona       : ${RPZ_ZONE}
  ║  Mode       : ${BLOCK_MODE}
  ║                                              ║
  ║  Dashboard  : http://<IP-server>:3000        ║
  ║  dnsdist key: cat /root/.dnsdist-key         ║
  ║  sync manual: rpz-sync --server ${RPZ_REMOTE} --zone ${RPZ_ZONE}
  ╚══════════════════════════════════════════════╝

MOTDEOF

# ── Initial RPZ sync (best-effort, tidak fatal jika gagal) ────
# Low-priority (nice/ionice) — di dalam chroot systemd belum jalan, jadi
# tanpa systemd-run; sync sudah fully streaming sehingga memori rendah.
chroot "$TARGET" nice -n 19 ionice -c3 /usr/local/bin/rpz-sync \
    --server "$RPZ_REMOTE" \
    --zone "$RPZ_ZONE" \
    --force \
    >> /tmp/install.log 2>&1 || true
