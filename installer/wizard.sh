#!/bin/sh
# Whiptail wizard — kumpulkan semua konfigurasi lalu jalankan installer

TITLE="internet-sehat DNS Installer"
CONF="/tmp/installer.conf"
LOG="/tmp/install.log"

# ── Helper ────────────────────────────────────────────────────
wt_msg() {
    whiptail --title "$TITLE — $1" --msgbox "$2" "${3:-14}" 72
}
wt_input() {
    # wt_input "title" "prompt" "default"
    whiptail --title "$TITLE — $1" --inputbox "$2" 10 72 "$3" \
        3>&1 1>&2 2>&3
}
wt_menu() {
    local title="$1" prompt="$2"; shift 2
    whiptail --title "$TITLE — $title" \
        --menu "$prompt" 18 72 8 "$@" 3>&1 1>&2 2>&3
}
wt_yn() {
    whiptail --title "$TITLE — $1" --yesno "$2" 14 72
}

abort() {
    wt_msg "Dibatalkan" \
        "Instalasi dibatalkan.\n\nReboot untuk memulai kembali:\n  reboot -f"
    exec /bin/sh
}

die() {
    wt_msg "Error" "$1"
    exec /bin/sh
}

# ── Welcome ───────────────────────────────────────────────────
whiptail --title "$TITLE" --msgbox \
"Selamat datang di internet-sehat DNS Installer.

Wizard ini akan mengkonfigurasi dan menginstall:
  • Debian minimal — sistem operasi ringan (~800 MB)
  • dnsdist        — DNS server berkinerja tinggi
  • RPZ blocklist  — filter domain dari Komdigi

Koneksi internet diperlukan untuk mengunduh paket.
Semua data pada disk tujuan akan DIHAPUS.

Tekan Enter untuk memulai." 18 72

# ── Step 1: Disk ──────────────────────────────────────────────
# Tulis daftar disk ke file (hindari subshell variable scope issue)
DISKS_FILE="/tmp/disks.txt"
lsblk -dn -o NAME,SIZE 2>/dev/null | grep -Ev '^(loop|sr)' > "$DISKS_FILE"

[ -s "$DISKS_FILE" ] || die "Tidak ada disk ditemukan. Pastikan disk terpasang."

# Bangun perintah whiptail secara dinamis via eval agar spasi di
# nama/ukuran tidak memecah argumen (masalah word-splitting di sh)
MENU_CMD="whiptail --title '$TITLE — 1/5  Target Disk' \
    --menu 'Pilih disk untuk instalasi:\n\n* Semua data pada disk ini akan DIHAPUS!' \
    18 72 8"
while read -r name size; do
    MENU_CMD="$MENU_CMD '/dev/$name' '$size'"
done < "$DISKS_FILE"
MENU_CMD="$MENU_CMD 3>&1 1>&2 2>&3"

TARGET_DISK=$(eval "$MENU_CMD") || abort

# ── Step 2: Hostname ──────────────────────────────────────────
while true; do
    HOSTNAME=$(wt_input "2/6  Hostname" \
        "Nama host untuk server DNS ini." \
        "internet-sehat-dns") || abort
    [ -n "$HOSTNAME" ] && break
    wt_msg "Error" "Hostname tidak boleh kosong."
done

# ── Step 2b: Root Password ────────────────────────────────────
while true; do
    ROOT_PASS=$(whiptail --title "$TITLE — 2/6  Root Password" \
        --passwordbox "Password untuk akun root server ini." 10 72 "" \
        3>&1 1>&2 2>&3) || abort
    [ -n "$ROOT_PASS" ] || { wt_msg "Error" "Password tidak boleh kosong."; continue; }
    ROOT_PASS2=$(whiptail --title "$TITLE — 2/6  Konfirmasi Password" \
        --passwordbox "Ulangi password." 10 72 "" \
        3>&1 1>&2 2>&3) || abort
    [ "$ROOT_PASS" = "$ROOT_PASS2" ] && break
    wt_msg "Error" "Password tidak cocok. Coba lagi."
done

# ── Step 3: Jaringan ──────────────────────────────────────────
NET_MODE=$(wt_menu "3/5  Jaringan" \
    "Mode jaringan untuk server DNS ini:" \
    "static" "Static IP — tetap (direkomendasikan untuk DNS server)" \
    "dhcp"   "DHCP      — IP otomatis dari router") || abort

STATIC_IP="" STATIC_MASK="255.255.255.0" STATIC_GW="" STATIC_DNS="1.1.1.1"

if [ "$NET_MODE" = "static" ]; then
    while true; do
        STATIC_IP=$(wt_input "3/6  IP Address" \
            "IP address statis untuk server ini.\nContoh: 192.168.1.10" \
            "") || abort
        [ -n "$STATIC_IP" ] && break
        wt_msg "Error" "IP tidak boleh kosong."
    done

    STATIC_MASK=$(wt_input "3/6  Subnet Mask" \
        "Subnet mask." "255.255.255.0") || abort

    while true; do
        STATIC_GW=$(wt_input "3/6  Gateway" \
            "IP address gateway/router.\nContoh: 192.168.1.1" "") || abort
        [ -n "$STATIC_GW" ] && break
        wt_msg "Error" "Gateway tidak boleh kosong."
    done

    STATIC_DNS=$(wt_input "3/6  DNS Sementara" \
        "DNS untuk proses instalasi (akan digantikan setelah install)." \
        "1.1.1.1") || abort
fi

# ── Step 4: RPZ Server ───────────────────────────────────────
while true; do
    RPZ_REMOTE=$(wt_input "4/6  RPZ Remote Server" \
        "IP address server RPZ Komdigi.\nDigunakan untuk AXFR/IXFR zone transfer." \
        "") || abort
    [ -n "$RPZ_REMOTE" ] && break
    wt_msg "Error" "RPZ remote server tidak boleh kosong."
done

RPZ_ZONE=$(wt_input "4/6  Nama Zona RPZ" \
    "Nama zona RPZ dari Komdigi." \
    "trustpositifkominfo") || abort
[ -n "$RPZ_ZONE" ] || RPZ_ZONE="trustpositifkominfo"

# ── Step 5: Block Mode ────────────────────────────────────────
BLOCK_MODE=$(wt_menu "5/6  Mode Blokir" \
    "Respons untuk domain yang diblokir:" \
    "nxdomain" "NXDOMAIN — domain seolah tidak ada (direkomendasikan)" \
    "redirect"  "Redirect  — arahkan ke halaman pemberitahuan") || abort

REDIRECT_IP="0.0.0.0"
if [ "$BLOCK_MODE" = "redirect" ]; then
    while true; do
        REDIRECT_IP=$(wt_input "5/6  Redirect IP" \
            "IP webserver halaman blokir." "") || abort
        [ -n "$REDIRECT_IP" ] && break
        wt_msg "Error" "Redirect IP tidak boleh kosong."
    done
fi

# ── Konfirmasi ────────────────────────────────────────────────
NET_DETAIL="$NET_MODE"
[ "$NET_MODE" = "static" ] && NET_DETAIL="$STATIC_IP / $STATIC_MASK gw $STATIC_GW"

BLOCK_DETAIL="$BLOCK_MODE"
[ "$BLOCK_MODE" = "redirect" ] && BLOCK_DETAIL="$BLOCK_MODE → $REDIRECT_IP"

wt_yn "Konfirmasi Instalasi" \
"Ringkasan:

  Disk target  : $TARGET_DISK  ⚠ DATA AKAN DIHAPUS
  Hostname     : $HOSTNAME
  Jaringan     : $NET_DETAIL
  RPZ remote   : $RPZ_REMOTE
  Zona RPZ     : $RPZ_ZONE
  Mode blokir  : $BLOCK_DETAIL

Lanjutkan instalasi?" || abort

# ── Simpan config ─────────────────────────────────────────────
cat > "$CONF" << EOF
TARGET_DISK="$TARGET_DISK"
HOSTNAME="$HOSTNAME"
ROOT_PASS="$ROOT_PASS"
NET_MODE="$NET_MODE"
STATIC_IP="$STATIC_IP"
STATIC_MASK="$STATIC_MASK"
STATIC_GW="$STATIC_GW"
STATIC_DNS="$STATIC_DNS"
RPZ_REMOTE="$RPZ_REMOTE"
RPZ_ZONE="$RPZ_ZONE"
BLOCK_MODE="$BLOCK_MODE"
REDIRECT_IP="$REDIRECT_IP"
EOF

# Log semua variable untuk debug
{
    echo "=== wizard.sh collected variables ==="
    echo "TARGET_DISK : [$TARGET_DISK]"
    echo "HOSTNAME    : [$HOSTNAME]"
    echo "NET_MODE    : [$NET_MODE]"
    echo "STATIC_IP   : [$STATIC_IP]"
    echo "STATIC_MASK : [$STATIC_MASK]"
    echo "STATIC_GW   : [$STATIC_GW]"
    echo "STATIC_DNS  : [$STATIC_DNS]"
    echo "RPZ_REMOTE  : [$RPZ_REMOTE]"
    echo "RPZ_ZONE    : [$RPZ_ZONE]"
    echo "BLOCK_MODE  : [$BLOCK_MODE]"
    echo "REDIRECT_IP : [$REDIRECT_IP]"
    echo "=== disk list (lsblk) ==="
    cat "$DISKS_FILE"
    echo "=== installer.conf ==="
    cat "$CONF"
    echo "======================================"
} >> "$LOG"

# ── Jalankan installer ────────────────────────────────────────
script -q -c "/installer/install-os.sh" /dev/null 2>>"$LOG"
RC=$?

if [ $RC -ne 0 ]; then
    wt_msg "Instalasi Gagal" \
        "Terjadi kesalahan saat instalasi.\nLog tersedia di $LOG\n\nShell darurat akan dibuka."
    exec /bin/sh
fi

if grep -q 'installer_debug=1' /proc/cmdline 2>/dev/null; then
    wt_msg "Selesai (debug)" \
        "✓ Instalasi selesai!\n\nMode debug aktif — tidak reboot.\nShell tersedia untuk inspeksi:\n  cat /tmp/install.log\n  lsblk\n  mount | grep /mnt"
    exec /bin/sh
fi

wt_msg "Selesai" \
    "✓ Instalasi selesai!\n\nCabut ISO/media installer sekarang.\nServer akan reboot dalam 10 detik."
sleep 10
reboot -f
