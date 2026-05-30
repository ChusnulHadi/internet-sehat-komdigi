#!/usr/bin/env bash
# =============================================================
# build-iso.sh — Build internet-sehat DNS Custom Live ISO
#
# Membuat bootable ISO dengan installer kustom berbasis
# Alpine Linux minimal (live env) + Debian Bookworm (target).
#
# Flow instalasi:
#   Boot ISO → wizard konfigurasi → install Debian minimal
#   → configure DNS → reboot → DNS server siap
#
# ISO size : ~80 MB
# Installed: ~800 MB
# Kompatibel: VM (QEMU/KVM, VirtualBox, VMware) + bare-metal
#             BIOS legacy + UEFI
#
# Dependensi build:
#   apt-get install grub-pc-bin grub-efi-amd64-bin \
#                   xorriso mtools curl openssl
#
# Penggunaan:
#   sudo bash build-iso.sh [--out PATH]
# =============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Default ───────────────────────────────────────────────────
ALPINE_BRANCH="v3.21"
OUT_ISO="${SCRIPT_DIR}/internet-sehat-dns.iso"
CACHE_DIR="${SCRIPT_DIR}/.cache"

# ── Warna ─────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }
section() { echo -e "\n${BOLD}▶ $*${NC}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_ISO="$2"; shift 2 ;;
    *) die "Argumen tidak dikenal: $1" ;;
  esac
done

# ── Preflight ─────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Jalankan sebagai root: sudo bash build-iso.sh"

for cmd in grub-mkrescue curl openssl mtools xorriso; do
  command -v "$cmd" &>/dev/null || die \
    "Dependensi tidak ditemukan: $cmd
Install: apt-get install grub-pc-bin grub-efi-amd64-bin xorriso mtools curl openssl"
done

[[ -f "$SCRIPT_DIR/installer/init" ]]       || die "installer/init tidak ditemukan"
[[ -f "$SCRIPT_DIR/installer/wizard.sh" ]]  || die "installer/wizard.sh tidak ditemukan"
[[ -f "$SCRIPT_DIR/installer/install-os.sh" ]] || die "installer/install-os.sh tidak ditemukan"
[[ -f "$SCRIPT_DIR/installer/config-dns.sh" ]] || die "installer/config-dns.sh tidak ditemukan"
[[ -f "$SCRIPT_DIR/dns/dnsdist.conf" ]]     || die "dns/dnsdist.conf tidak ditemukan"

# ── Workdir ───────────────────────────────────────────────────
WORKDIR="$(mktemp -d /tmp/is-build.XXXXXX)"
ROOTFS="$WORKDIR/rootfs"
ISO_DIR="$WORKDIR/iso"

cleanup() {
  for mp in "$ROOTFS/var/cache/apk" "$ROOTFS/dev/pts" "$ROOTFS/dev" "$ROOTFS/sys" "$ROOTFS/proc"; do
    mountpoint -q "$mp" 2>/dev/null && umount "$mp" || true
  done
  rm -rf "$WORKDIR"
  info "Temp files dibersihkan"
}
trap cleanup EXIT

mkdir -p "$ROOTFS" "$ISO_DIR/boot/grub" "$CACHE_DIR/apk"

# =============================================================
section "1. Alpine minirootfs"
# =============================================================

# Cari versi terbaru dari branch yang dipilih
info "Mencari versi Alpine terbaru di branch ${ALPINE_BRANCH}..."
ALPINE_VERSION=$(curl -sL \
  "https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/releases/x86_64/" \
  | grep -oP 'alpine-minirootfs-\K[\d.]+(?=-x86_64\.tar\.gz)' \
  | sort -V | tail -1)

[[ -n "$ALPINE_VERSION" ]] || die "Gagal mendapatkan versi Alpine. Cek koneksi internet."
info "Versi ditemukan: Alpine ${ALPINE_VERSION}"

ROOTFS_URL="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/releases/x86_64/alpine-minirootfs-${ALPINE_VERSION}-x86_64.tar.gz"
ROOTFS_TAR="$CACHE_DIR/alpine-minirootfs-${ALPINE_VERSION}-x86_64.tar.gz"

if [[ -f "$ROOTFS_TAR" ]]; then
  info "Menggunakan cache: $ROOTFS_TAR"
else
  info "Mengunduh Alpine minirootfs..."
  curl -sL --progress-bar -o "$ROOTFS_TAR" "$ROOTFS_URL" \
    || { rm -f "$ROOTFS_TAR"; die "Gagal mengunduh Alpine minirootfs"; }
fi

info "Mengekstrak rootfs..."
tar -xzf "$ROOTFS_TAR" -C "$ROOTFS"
ok "Alpine ${ALPINE_VERSION} siap"

# =============================================================
section "2. Setup chroot + install packages"
# =============================================================

# Setup chroot
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
mount --bind /proc    "$ROOTFS/proc"
mount --bind /sys     "$ROOTFS/sys"
mount --bind /dev     "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"

# Bind mount APK cache supaya packages tidak re-download setiap build
mkdir -p "$ROOTFS/var/cache/apk"
mount --bind "$CACHE_DIR/apk" "$ROOTFS/var/cache/apk"
# Alpine membutuhkan symlink /etc/apk/cache untuk aktifkan caching
ln -sf /var/cache/apk "$ROOTFS/etc/apk/cache"

# Enable community repo (dibutuhkan untuk debootstrap)
cat >> "$ROOTFS/etc/apk/repositories" \
  <<< "https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/community"

info "Menginstall packages ke rootfs (ini membutuhkan beberapa menit)..."
chroot "$ROOTFS" /bin/sh -c "
  apk update --no-cache -q
  apk add -q \
    linux-lts \
    libmount \
    newt \
    debootstrap \
    parted \
    e2fsprogs \
    dosfstools \
    util-linux \
    iproute2 \
    openssl \
    curl \
    ca-certificates \
    openntpd \
" || die "Gagal menginstall packages ke rootfs"
ok "Packages terinstall"

# Ekstrak kernel dari rootfs ke ISO (kernel tidak perlu ada di dalam initrd)
info "Mengekstrak kernel dari linux-lts..."
VMLINUZ_PATH=$(ls "$ROOTFS"/boot/vmlinuz-lts 2>/dev/null || ls "$ROOTFS"/boot/vmlinuz* 2>/dev/null | head -1)
[[ -f "$VMLINUZ_PATH" ]] || die "Kernel tidak ditemukan. Pastikan linux-lts terinstall."
cp "$VMLINUZ_PATH" "$ISO_DIR/vmlinuz"
ok "Kernel: $(du -sh "$ISO_DIR/vmlinuz" | cut -f1)"

# Hapus /boot dari rootfs — tidak diperlukan di dalam initrd
rm -rf "$ROOTFS/boot"

# ── Diagnostik ukuran rootfs sebelum pruning ─────────────────────────────
info "=== Breakdown rootfs ==="
du -sh "$ROOTFS"/* 2>/dev/null | sort -rh || true
info "=== Breakdown /lib/ ==="
for d in "$ROOTFS/lib"/*/; do
    [[ -d "$d" ]] || continue
    echo "  $(du -sh "$d" 2>/dev/null | cut -f1)    $(basename "$d")"
done
KVER=$(ls "$ROOTFS/lib/modules/" 2>/dev/null | head -1) || true
if [[ -z "${KVER:-}" ]]; then
    warn "PERINGATAN: /lib/modules/ kosong — linux-lts tidak terinstall!"
else
    info "Kernel version: $KVER"
    info "=== Breakdown drivers/ ==="
    for d in "$ROOTFS/lib/modules/$KVER/kernel/drivers"/*/; do
        [[ -d "$d" ]] || continue
        echo "  $(du -sh "$d" 2>/dev/null | cut -f1)    $(basename "$d")"
    done | sort -rh || true
fi

# ── Prune kernel modules ─────────────────────────────────────────────────
info "Memangkas kernel modules (whitelist)..."
KMOD="$ROOTFS/lib/modules/$KVER/kernel"

if [[ ! -d "$KMOD" ]]; then
    warn "KMOD directory tidak ditemukan: $KMOD — skip pruning"
else
    BEFORE=$(find "$KMOD" -name "*.ko*" | wc -l)

    # Pass 1: hapus semua modul di luar whitelist
    find "$KMOD" -name "*.ko*" \
        ! -path "*/drivers/nvme/*"             \
        ! -path "*/drivers/block/*"            \
        ! -path "*/drivers/mmc/*"              \
        ! -path "*/drivers/usb/host/*"         \
        ! -path "*/drivers/usb/storage/*"      \
        ! -path "*/drivers/net/ethernet/intel/*"    \
        ! -path "*/drivers/net/ethernet/realtek/*"  \
        ! -path "*/drivers/net/ethernet/broadcom/*" \
        ! -path "*/drivers/net/ethernet/marvell/*"  \
        ! -path "*/lib/*"                      \
        -delete

    # Pass 2: scsi/ simpan hanya core + virtio-scsi (untuk Proxmox/KVM)
    find "$KMOD/drivers/scsi" -name "*.ko*" \
        ! -name "sd_mod.ko*"      \
        ! -name "sr_mod.ko*"      \
        ! -name "sg.ko*"          \
        ! -name "virtio_scsi.ko*" \
        -delete 2>/dev/null || true

    find "$KMOD" -type d -empty -delete 2>/dev/null || true
    chroot "$ROOTFS" depmod -a 2>/dev/null || true

    AFTER=$(find "$KMOD" -name "*.ko*" | wc -l)
    MSIZE=$(du -sh "$ROOTFS/lib/modules" | cut -f1)
    ok "Modules: $BEFORE → $AFTER files, ukuran: ${MSIZE}"
fi

info "=== Breakdown rootfs setelah pruning ==="
du -sh "$ROOTFS"/* 2>/dev/null | sort -rh || true

# =============================================================
section "3. Build dashboard & copy installer scripts"
# =============================================================

# Build dashboard jika belum ada
STANDALONE="$SCRIPT_DIR/dashboard/.next/standalone"
if [[ ! -d "$STANDALONE" ]]; then
  info "Building dashboard (npm ci && npm run build)..."
  command -v node &>/dev/null || die "node tidak ditemukan — install Node.js 18+ untuk build dashboard"
  (cd "$SCRIPT_DIR/dashboard" && npm ci && npm run build)
fi
[[ -f "$STANDALONE/server.js" ]] || die "Dashboard standalone build tidak ditemukan: $STANDALONE/server.js"

mkdir -p "$ROOTFS/installer/dns" "$ROOTFS/installer/dashboard"

install -m 755 "$SCRIPT_DIR/installer/init"           "$ROOTFS/init"
install -m 755 "$SCRIPT_DIR/installer/wizard.sh"      "$ROOTFS/installer/wizard.sh"
install -m 755 "$SCRIPT_DIR/installer/install-os.sh"  "$ROOTFS/installer/install-os.sh"
install -m 755 "$SCRIPT_DIR/installer/config-dns.sh"  "$ROOTFS/installer/config-dns.sh"

# DNS config files (digunakan oleh config-dns.sh)
cp "$SCRIPT_DIR/dns/dnsdist.conf"  "$ROOTFS/installer/dns/"
cp "$SCRIPT_DIR/dns/rpz2cdb.py"    "$ROOTFS/installer/dns/"
cp "$SCRIPT_DIR/dns/rpz-sync.py"   "$ROOTFS/installer/dns/"
cp "$SCRIPT_DIR/dns/test.sh"       "$ROOTFS/installer/dns/"
cp "$SCRIPT_DIR/dns/build-cdb.sh"  "$ROOTFS/installer/dns/"

# Dashboard pre-built standalone (digunakan oleh config-dns.sh)
cp -r "$STANDALONE/."                                "$ROOTFS/installer/dashboard/"
mkdir -p "$ROOTFS/installer/dashboard/.next"
cp -r "$SCRIPT_DIR/dashboard/.next/static"          "$ROOTFS/installer/dashboard/.next/static"
cp -r "$SCRIPT_DIR/dashboard/public"                "$ROOTFS/installer/dashboard/public"

ok "Installer scripts + dashboard tersalin"

# =============================================================
section "4. Build initrd"
# =============================================================

# Unmount semua bind mounts sebelum pack initrd
umount "$ROOTFS/var/cache/apk"
umount "$ROOTFS/dev/pts"
umount "$ROOTFS/dev"
umount "$ROOTFS/sys"
umount "$ROOTFS/proc"

info "Membuat initrd.gz..."
(
  cd "$ROOTFS"
  # Hapus file yang tidak perlu untuk mengecilkan initrd
  rm -rf \
    usr/share/doc \
    usr/share/man \
    usr/share/info \
    usr/share/locale \
    usr/share/terminfo \
    var/cache/apk \
    var/cache/misc \
    var/lib/apk \
    lib/firmware \
    tmp/* \
    2>/dev/null || true

  info "=== Ukuran komponen initrd ==="
  du -sh ./* 2>/dev/null | sort -rh || true

  find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$ISO_DIR/initrd.gz"
  ok "initrd.gz: $(du -sh "$ISO_DIR/initrd.gz" | cut -f1)"
)

INITRD_SIZE=$(du -sh "$ISO_DIR/initrd.gz" | cut -f1)
ok "initrd.gz: ${INITRD_SIZE}"

# =============================================================
section "5. GRUB config"
# =============================================================

cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUBEOF'
set default=0
set timeout=5

if loadfont /boot/grub/font.pf2; then
  set gfxmode=auto
  insmod efi_gop
  insmod efi_uga
  insmod gfxterm
  terminal_output gfxterm
fi

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "internet-sehat DNS Installer" {
    linux  /vmlinuz quiet loglevel=0
    initrd /initrd.gz
}

menuentry "internet-sehat DNS Installer (debug — no reboot)" {
    linux  /vmlinuz installer_debug=1
    initrd /initrd.gz
}

menuentry "Boot from local disk" {
    exit
}
GRUBEOF

ok "GRUB config siap"

# =============================================================
section "6. Build ISO"
# =============================================================

rm -f "$OUT_ISO"
info "Membangun ISO dengan grub-mkrescue..."

grub-mkrescue \
  --output="$OUT_ISO" \
  "$ISO_DIR" \
  2>&1 | grep -v "^grub-mkrescue" || true

[[ -f "$OUT_ISO" ]] || die "ISO gagal dibuat."

ISO_SIZE=$(du -sh "$OUT_ISO" | cut -f1)
ok "ISO berhasil: $OUT_ISO (${ISO_SIZE})"

# =============================================================
echo ""
echo -e "${GREEN}${BOLD}✓ Build selesai!${NC}"
echo ""
echo "  Output ISO  : $OUT_ISO"
echo "  Ukuran ISO  : $ISO_SIZE"
echo ""
echo "  Cara pakai:"
echo "  ┌─ VM ──────────────────────────────────────────────────"
echo "  │  Boot VM dari ISO → wizard langsung muncul"
echo "  │  Butuh: koneksi internet saat instalasi"
echo "  └───────────────────────────────────────────────────────"
echo "  ┌─ Bare metal (USB) ────────────────────────────────────"
echo "  │  dd if=$OUT_ISO of=/dev/sdX bs=4M status=progress"
echo "  └───────────────────────────────────────────────────────"
echo ""
echo -e "  ${YELLOW}PERINGATAN: Disk tujuan akan DIHAPUS saat instalasi!${NC}"
echo ""
