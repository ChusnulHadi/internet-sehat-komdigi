#!/bin/bash
# Pengganti systemctl — install.sh berjalan tanpa modifikasi di dalam container
CMD="${1:-}"

case "$CMD" in
  enable|disable|daemon-reload)
    exit 0
    ;;
  start|restart)
    # Touch config supaya entrypoint watchdog mendeteksi dan (re)start dnsdist
    touch /etc/dnsdist/dnsdist.conf 2>/dev/null || true
    exit 0
    ;;
  is-active)
    pgrep -x dnsdist >/dev/null 2>&1 && exit 0 || exit 3
    ;;
  status)
    pgrep -x dnsdist >/dev/null 2>&1 \
      && echo "● dnsdist.service - active (running) [container]" \
      || echo "● dnsdist.service - inactive (dead) [container]"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
