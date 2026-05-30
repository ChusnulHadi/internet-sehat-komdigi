#!/usr/bin/env bash
# =============================================================
# test.sh - Verifikasi dnsdist berjalan dengan benar
# =============================================================
# Jalankan SETELAH dnsdist aktif
# =============================================================

set -euo pipefail

DNS_SERVER="${1:-127.0.0.1}"
DNS_PORT="${2:-53}"

# Warna output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

if ! command -v dig &>/dev/null; then
  echo "Install dig dulu: sudo apt install dnsutils"
  exit 1
fi

echo ""
echo "==========================================="
echo " DNS Test - server: $DNS_SERVER:$DNS_PORT"
echo "==========================================="
echo ""

FAILED=0

# ----- Test 1: Domain normal (harus resolve) -----
info "Test 1: Domain normal harus resolve..."
RESULT=$(dig +short +time=3 @"$DNS_SERVER" -p "$DNS_PORT" google.com A 2>/dev/null || echo "TIMEOUT")
if [[ "$RESULT" == "TIMEOUT" || -z "$RESULT" ]]; then
  fail "google.com tidak resolve → upstream mungkin bermasalah"
  FAILED=$((FAILED+1))
else
  pass "google.com → $RESULT"
fi

# ----- Test 2: Domain di blocklist (harus NXDOMAIN) -----
info "Test 2: Domain di blocklist harus NXDOMAIN..."
RCODE=$(dig +short +time=3 @"$DNS_SERVER" -p "$DNS_PORT" pornhub.com A 2>/dev/null
        dig +time=3 @"$DNS_SERVER" -p "$DNS_PORT" pornhub.com A 2>/dev/null | grep -oP 'status: \K\w+' || echo "UNKNOWN")

if echo "$RCODE" | grep -q "NXDOMAIN"; then
  pass "pornhub.com → NXDOMAIN (terblokir)"
else
  fail "pornhub.com → $RCODE (seharusnya NXDOMAIN)"
  FAILED=$((FAILED+1))
fi

# ----- Test 3: Cek status service -----
info "Test 3: Cek dnsdist service..."
if systemctl is-active --quiet dnsdist 2>/dev/null; then
  pass "dnsdist service aktif"
elif pgrep -x dnsdist &>/dev/null; then
  pass "dnsdist process berjalan"
else
  fail "dnsdist tidak berjalan"
  FAILED=$((FAILED+1))
fi

# ----- Test 4: Port 53 terbuka -----
info "Test 4: Port 53 terbuka..."
if ss -ulnp 2>/dev/null | grep -q ":53 "; then
  pass "Port 53 UDP terbuka"
elif ss -tlnp 2>/dev/null | grep -q ":53 "; then
  pass "Port 53 TCP terbuka"
else
  fail "Port 53 tidak terbuka"
  FAILED=$((FAILED+1))
fi

# ----- Test 5: Latency -----
info "Test 5: Latency test..."
START=$(date +%s%3N)
dig +short +time=3 @"$DNS_SERVER" -p "$DNS_PORT" cloudflare.com A &>/dev/null || true
END=$(date +%s%3N)
LATENCY=$((END-START))
if [[ $LATENCY -lt 200 ]]; then
  pass "Latency: ${LATENCY}ms"
elif [[ $LATENCY -lt 500 ]]; then
  echo -e "${YELLOW}[WARN]${NC} Latency agak tinggi: ${LATENCY}ms"
else
  fail "Latency tinggi: ${LATENCY}ms"
  FAILED=$((FAILED+1))
fi

echo ""
echo "==========================================="
if [[ $FAILED -eq 0 ]]; then
  echo -e "${GREEN}Semua test PASS${NC}"
else
  echo -e "${RED}${FAILED} test FAIL${NC}"
fi
echo "==========================================="
echo ""
