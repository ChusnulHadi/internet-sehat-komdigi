#!/bin/sh
# Silent OS installer — partition, debootstrap, configure, GRUB

set -e
. /tmp/installer.conf

TITLE="internet-sehat DNS Installer"
LOG="/tmp/install.log"
TARGET="/mnt"
DEBIAN_MIRROR="https://deb.debian.org/debian"
DEBIAN_RELEASE="bookworm"

# Log semua variable setelah source conf
{
    echo "=== install-os.sh sourced variables ==="
    echo "TARGET_DISK : [$TARGET_DISK]"
    echo "HOSTNAME    : [$HOSTNAME]"
    echo "NET_MODE    : [$NET_MODE]"
    echo "STATIC_IP   : [$STATIC_IP]"
    echo "STATIC_GW   : [$STATIC_GW]"
    echo "RPZ_REMOTE  : [$RPZ_REMOTE]"
    echo "RPZ_ZONE    : [$RPZ_ZONE]"
    echo "BLOCK_MODE  : [$BLOCK_MODE]"
    echo "======================================="
} >> "$LOG"

# progress() — output ke stdout (pipe ke whiptail gauge)
# SEMUA command lain harus >> "$LOG" 2>&1, jangan campur ke stdout
progress() {
    echo "XXX"; echo "$2"; echo "$1"; echo "XXX"
}

# ── Detect UEFI / BIOS ────────────────────────────────────────
BOOT_MODE="bios"
[ -d /sys/firmware/efi ] && BOOT_MODE="uefi"
echo "BOOT_MODE   : [$BOOT_MODE]" >> "$LOG"

# ── Main installation subshell ────────────────────────────────
# stdout dari subshell ini masuk ke whiptail gauge.
# SEMUA command harus redirect ke LOG agar tidak corrupt gauge output.
(
    set -e

    progress "Membuat partisi..." 5

    case "$TARGET_DISK" in
        *nvme*|*mmcblk*) PART_PREFIX="${TARGET_DISK}p" ;;
        *) PART_PREFIX="${TARGET_DISK}" ;;
    esac

    {
        echo "--- partition vars ---"
        echo "  TARGET_DISK : [$TARGET_DISK]"
        echo "  BOOT_MODE   : [$BOOT_MODE]"
        echo "  PART_PREFIX : [$PART_PREFIX]"
    } >> "$LOG"

    if [ "$BOOT_MODE" = "uefi" ]; then
        PART_EFI="${PART_PREFIX}1"
        PART_ROOT="${PART_PREFIX}2"
        echo "  PART_EFI    : [$PART_EFI]"  >> "$LOG"
        echo "  PART_ROOT   : [$PART_ROOT]" >> "$LOG"
        parted -s "$TARGET_DISK" mklabel gpt                         >> "$LOG" 2>&1
        parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 512MiB   >> "$LOG" 2>&1
        parted -s "$TARGET_DISK" set 1 esp on                        >> "$LOG" 2>&1
        parted -s "$TARGET_DISK" mkpart primary ext4 512MiB 100%     >> "$LOG" 2>&1
        # Force kernel re-read partition table
        blockdev --rereadpt "$TARGET_DISK" >> "$LOG" 2>&1 || true
        sleep 2
        mdev -s 2>/dev/null || true
        echo "--- /dev setelah parted ---"        >> "$LOG"
        ls /dev/"$(basename "$TARGET_DISK")"* >> "$LOG" 2>&1 || true
        echo "  check PART_EFI  [$PART_EFI]  : $(ls -la "$PART_EFI"  2>&1)" >> "$LOG"
        echo "  check PART_ROOT [$PART_ROOT] : $(ls -la "$PART_ROOT" 2>&1)" >> "$LOG"
        mkfs.fat -F32 "$PART_EFI"                                    >> "$LOG" 2>&1
    else
        PART_ROOT="${PART_PREFIX}1"
        echo "  PART_ROOT   : [$PART_ROOT]" >> "$LOG"
        parted -s "$TARGET_DISK" mklabel msdos                       >> "$LOG" 2>&1
        parted -s "$TARGET_DISK" mkpart primary ext4 1MiB 100%       >> "$LOG" 2>&1
        parted -s "$TARGET_DISK" set 1 boot on                       >> "$LOG" 2>&1
        # Force kernel re-read partition table
        blockdev --rereadpt "$TARGET_DISK" >> "$LOG" 2>&1 || true
        sleep 2
        mdev -s 2>/dev/null || true
        echo "--- /dev setelah parted ---"        >> "$LOG"
        ls /dev/"$(basename "$TARGET_DISK")"* >> "$LOG" 2>&1 || true
        echo "  check PART_ROOT [$PART_ROOT] : $(ls -la "$PART_ROOT" 2>&1)" >> "$LOG"
    fi

    progress "Memformat partisi..." 10
    echo "--- mkfs.ext4 on [$PART_ROOT] ---" >> "$LOG"
    ls -la "$PART_ROOT" >> "$LOG" 2>&1 || { echo "ERROR: $PART_ROOT tidak ditemukan sebelum mkfs!" >> "$LOG"; exit 1; }
    mkfs.ext4 -F -L root "$PART_ROOT" >> "$LOG" 2>&1

    echo "PART_ROOT=\"$PART_ROOT\""    >> /tmp/installer.conf
    echo "PART_EFI=\"${PART_EFI:-}\""  >> /tmp/installer.conf

    progress "Mount partisi..." 12
    echo "--- pre-mount check ---" >> "$LOG"
    echo "  PART_ROOT=[${PART_ROOT}] exists=$(ls "$PART_ROOT" 2>&1)" >> "$LOG"
    echo "  TARGET=[${TARGET}]" >> "$LOG"
    echo "--- mount [$PART_ROOT] -> [$TARGET] ---" >> "$LOG"
    mount "$PART_ROOT" "$TARGET"                    >> "$LOG" 2>&1
    if [ "$BOOT_MODE" = "uefi" ]; then
        mkdir -p "$TARGET/boot/efi"
        echo "  PART_EFI=[${PART_EFI}] exists=$(ls "$PART_EFI" 2>&1)" >> "$LOG"
        echo "--- mount [$PART_EFI] -> [$TARGET/boot/efi] ---" >> "$LOG"
        mount "$PART_EFI" "$TARGET/boot/efi"        >> "$LOG" 2>&1
    fi

    # Konfigurasi jaringan static untuk proses download
    if [ "$NET_MODE" = "static" ]; then
        LIVE_IFACE=""
        for _i in 1 2 3 4 5; do
            LIVE_IFACE=$(ls /sys/class/net/ | grep -Ev '^(lo|sit)' | head -1)
            [ -n "$LIVE_IFACE" ] && break
            sleep 1
        done
        echo "  LIVE_IFACE  : [$LIVE_IFACE]" >> "$LOG"
        [ -n "$LIVE_IFACE" ] || { echo "ERROR: tidak ada network interface" >> "$LOG"; exit 1; }
        ip addr flush dev "$LIVE_IFACE"                               >> "$LOG" 2>&1
        ip addr add "${STATIC_IP}/${STATIC_MASK}" dev "$LIVE_IFACE"  >> "$LOG" 2>&1
        ip route add default via "$STATIC_GW"                        >> "$LOG" 2>&1 || true
        echo "nameserver $STATIC_DNS" > /etc/resolv.conf
    fi

    progress "Menginstall sistem Debian minimal... (beberapa menit)" 15
    debootstrap \
        --variant=minbase \
        --include=ca-certificates \
        "$DEBIAN_RELEASE" "$TARGET" "$DEBIAN_MIRROR"                 >> "$LOG" 2>&1

    progress "Mengkonfigurasi sistem..." 65

    # fstab
    ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
    {
        echo "UUID=$ROOT_UUID / ext4 errors=remount-ro 0 1"
        if [ "$BOOT_MODE" = "uefi" ]; then
            EFI_UUID=$(blkid -s UUID -o value "$PART_EFI")
            echo "UUID=$EFI_UUID /boot/efi vfat umask=0077 0 1"
        fi
        echo "tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0"
    } > "$TARGET/etc/fstab"

    # Hostname & hosts
    echo "$HOSTNAME" > "$TARGET/etc/hostname"
    printf '127.0.0.1 localhost\n127.0.1.1 %s\n::1 localhost ip6-localhost ip6-loopback\n' \
        "$HOSTNAME" > "$TARGET/etc/hosts"

    # APT sources
    cat > "$TARGET/etc/apt/sources.list" << SRCEOF
deb $DEBIAN_MIRROR $DEBIAN_RELEASE main
deb https://security.debian.org/debian-security ${DEBIAN_RELEASE}-security main
deb $DEBIAN_MIRROR ${DEBIAN_RELEASE}-updates main
SRCEOF

    # Network interfaces (force eth0)
    mkdir -p "$TARGET/etc/network"
    {
        echo "auto lo"
        echo "iface lo inet loopback"
        echo ""
        echo "auto eth0"
        if [ "$NET_MODE" = "static" ]; then
            echo "iface eth0 inet static"
            echo "    address $STATIC_IP"
            echo "    netmask $STATIC_MASK"
            echo "    gateway $STATIC_GW"
            echo "    dns-nameservers 1.1.1.1 1.0.0.1"
        else
            echo "iface eth0 inet dhcp"
        fi
    } > "$TARGET/etc/network/interfaces"

    echo "nameserver 1.1.1.1" > "$TARGET/etc/resolv.conf"
    echo "nameserver 1.0.0.1" >> "$TARGET/etc/resolv.conf"

    echo "LANG=en_US.UTF-8"  > "$TARGET/etc/locale.conf"
    echo "en_US.UTF-8 UTF-8" > "$TARGET/etc/locale.gen"
    ln -sf /usr/share/zoneinfo/Asia/Jakarta "$TARGET/etc/localtime"
    echo "Asia/Jakarta" > "$TARGET/etc/timezone"

    # Bind mounts untuk chroot
    mount --bind /proc    "$TARGET/proc"   >> "$LOG" 2>&1
    mount --bind /sys     "$TARGET/sys"    >> "$LOG" 2>&1
    mount --bind /dev     "$TARGET/dev"    >> "$LOG" 2>&1
    mount --bind /dev/pts "$TARGET/dev/pts" >> "$LOG" 2>&1

    progress "Menginstall paket..." 70
    chroot "$TARGET" /bin/sh -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y --no-install-recommends \
            dnsdist \
            freecdb \
            python3-minimal \
            nodejs \
            cron \
            openssh-server \
            curl \
            bind9-dnsutils \
            sudo \
            ifupdown \
            iproute2 \
            locales \
            linux-image-amd64 \
            systemd-sysv \
            grub2-common \
            grub-efi-amd64-bin \
            grub-pc-bin
    " >> "$LOG" 2>&1

    echo "root:${ROOT_PASS}" | chroot "$TARGET" chpasswd >> "$LOG" 2>&1

    progress "Mengkonfigurasi DNS server..." 85
    /installer/config-dns.sh >> "$LOG" 2>&1

    progress "Menginstall bootloader..." 92

    mkdir -p "$TARGET/etc/default"
    cat > "$TARGET/etc/default/grub" << GRUBEOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="internet-sehat DNS"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"
GRUBEOF

    if [ "$BOOT_MODE" = "uefi" ]; then
        chroot "$TARGET" grub-install \
            --target=x86_64-efi \
            --efi-directory=/boot/efi \
            --bootloader-id=internet-sehat \
            --no-nvram                       >> "$LOG" 2>&1
        mkdir -p "$TARGET/boot/efi/EFI/BOOT"
        cp "$TARGET/boot/efi/EFI/internet-sehat/grubx64.efi" \
           "$TARGET/boot/efi/EFI/BOOT/BOOTX64.EFI"            >> "$LOG" 2>&1 || true
    else
        chroot "$TARGET" grub-install \
            --target=i386-pc \
            "$TARGET_DISK"                   >> "$LOG" 2>&1
    fi
    chroot "$TARGET" update-grub             >> "$LOG" 2>&1

    progress "Membersihkan..." 98

    umount "$TARGET/dev/pts" 2>/dev/null || true
    umount "$TARGET/dev"     2>/dev/null || true
    umount "$TARGET/sys"     2>/dev/null || true
    umount "$TARGET/proc"    2>/dev/null || true
    [ "$BOOT_MODE" = "uefi" ] && umount "$TARGET/boot/efi" 2>/dev/null || true
    umount "$TARGET"         2>/dev/null || true
    sync

    echo "=== install-os.sh selesai ===" >> "$LOG"
    echo 100

) | whiptail --title "$TITLE — Instalasi" \
    --gauge "Mempersiapkan instalasi..." 8 72 0
