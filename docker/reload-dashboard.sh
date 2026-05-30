#!/bin/bash
# Reload dashboard — apply perubahan .env tanpa rebuild atau restart container
pkill -f "node /opt/dashboard/server.js" 2>/dev/null || true
echo "Dashboard akan restart dalam ~5 detik (watchdog)"
