#!/bin/bash
# Dijalankan otomatis saat root login pertama kali di tty1.
# Setelah install.sh selesai, autologin dan script ini dinonaktifkan.

MARKER="/opt/internet-sehat/.setup-pending"
AUTOLOGIN_CONF="/etc/systemd/system/getty@tty1.service.d/autologin.conf"

if [ -f "$MARKER" ] && [ -t 0 ]; then
    clear
    cd /opt/internet-sehat
    bash install.sh

    # Nonaktifkan first-boot: hapus marker dan autologin
    rm -f "$MARKER"
    rm -f "$AUTOLOGIN_CONF"
    systemctl daemon-reload
    systemctl restart getty@tty1.service
fi
