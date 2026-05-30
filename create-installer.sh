#!/usr/bin/env bash
# create-installer.sh — Buat paket zip untuk instalasi langsung (install.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:-$(date +%Y%m%d)}"
OUTPUT="$SCRIPT_DIR/internet-sehat-installer-${VERSION}.zip"

# ── Build dashboard jika belum ada ───────────────────────────
STANDALONE="$SCRIPT_DIR/dashboard/.next/standalone"
if [[ ! -d "$STANDALONE" ]]; then
  echo "Building dashboard (npm ci && npm run build)..."
  (cd "$SCRIPT_DIR/dashboard" && npm ci && npm run build)
fi

# ── Verifikasi file sumber ────────────────────────────────────
DNS_FILES=(
  install.sh
  dns/dnsdist.conf
  dns/rpz2cdb.py
  dns/rpz-sync.py
  dns/test.sh
)

cd "$SCRIPT_DIR"

for f in "${DNS_FILES[@]}"; do
  [[ -f "$f" ]] || { echo "ERROR: file tidak ditemukan: $f"; exit 1; }
done

[[ -f "$STANDALONE/server.js" ]] || {
  echo "ERROR: dashboard/server.js tidak ditemukan di standalone output"
  exit 1
}

# ── Staging ───────────────────────────────────────────────────
STAGE=$(mktemp -d)
trap "rm -rf '$STAGE'" EXIT

cp --parents "${DNS_FILES[@]}" "$STAGE/"

mkdir -p "$STAGE/dashboard"
cp -r "$STANDALONE/."                         "$STAGE/dashboard/"
mkdir -p "$STAGE/dashboard/.next"
cp -r "$SCRIPT_DIR/dashboard/.next/static"   "$STAGE/dashboard/.next/static"
cp -r "$SCRIPT_DIR/dashboard/public"         "$STAGE/dashboard/public"

# ── Buat zip ──────────────────────────────────────────────────
rm -f "$OUTPUT"
(cd "$STAGE" && zip -r "$OUTPUT" .)

echo "Installer dibuat: $OUTPUT"
echo "Isi:"
unzip -l "$OUTPUT"
