#!/usr/bin/env bash
# =============================================================
# build-cdb.sh
# Build CDB blocklist dari file domain list
# =============================================================
# Usage:
#   ./build-cdb.sh [domain-list-file] [output-cdb-path]
#
# Default:
#   input  = ./domains.txt
#   output = /opt/blocklist/blocklist.cdb
#
# Format file input: satu domain per baris, contoh:
#   pornhub.com
#   tiktok.com
#   # ini komentar, diabaikan
# =============================================================

set -euo pipefail

INPUT="${1:-./domains.txt}"
OUTPUT="${2:-/opt/blocklist/blocklist.cdb}"
OUTPUT_TMP="${OUTPUT}.tmp"
OUTPUT_DIR="$(dirname "$OUTPUT")"

# ----- dependency check -----
if ! command -v cdbmake &>/dev/null; then
  echo "[ERROR] cdbmake tidak ditemukan. Install dulu:"
  echo "        sudo apt install freecdb"
  exit 1
fi

if [[ ! -f "$INPUT" ]]; then
  echo "[ERROR] File domain list tidak ditemukan: $INPUT"
  exit 1
fi

# ----- prep -----
mkdir -p "$OUTPUT_DIR"

echo "[INFO] Building CDB dari: $INPUT"
echo "[INFO] Output: $OUTPUT"

# Hitung domain yang akan diproses (exclude komentar & baris kosong)
TOTAL=$(grep -cE '^[^#[:space:]]' "$INPUT" 2>/dev/null || echo 0)
echo "[INFO] Total domain: $TOTAL"

# ----- build CDB -----
# Format cdbmake: +keylen,datalen:key->value
# dnsdist KeyValueStoreKey.QName = qname lowercase tanpa trailing dot
# Contoh: "pornhub.com" → key = "pornhub.com"

{
  while IFS= read -r line; do
    # Skip komentar dan baris kosong
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # Trim whitespace dan lowercase
    domain=$(echo "$line" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

    # Skip kalau kosong setelah trim
    [[ -z "$domain" ]] && continue

    # Tulis record CDB: key=domain, value="1"
    printf "+%d,1:%s->1\n" "${#domain}" "$domain"
  done < "$INPUT"

  # Terminasi CDB (baris kosong)
  echo ""
} | cdbmake "$OUTPUT" "$OUTPUT_TMP"

# Verifikasi
if [[ -f "$OUTPUT" ]]; then
  SIZE=$(du -sh "$OUTPUT" | cut -f1)
  echo "[OK] CDB berhasil dibuat: $OUTPUT ($SIZE)"
else
  echo "[ERROR] CDB gagal dibuat"
  exit 1
fi

echo "[INFO] Reload dnsdist jika sedang berjalan:"
echo "       sudo systemctl reload dnsdist"
echo "       atau via console: pdnsutil dnsdist-stats (tidak perlu reload, CDB auto-refresh dalam ${CDB_REFRESH:-60}s)"
