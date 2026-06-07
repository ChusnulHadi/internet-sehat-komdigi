#!/usr/bin/env python3
"""
rpz-sync.py
Sync blocklist dari Komdigi RPZ via IXFR (incremental) / AXFR (full).

Flow:
  1. Cek SOA serial di remote server
  2. Bandingkan dengan serial lokal
  3. Kalau sama → skip (tidak ada perubahan)
  4. Kalau beda:
     a. Coba IXFR → parse delta (add/delete) → apply ke exact-domains.txt → rebuild CDB
     b. Kalau IXFR gagal atau first-run → AXFR → full rebuild

Usage:
  rpz-sync --server <IP> [--zone trustpositifkominfo] [--force]
"""

import sys
import os
import subprocess
import argparse
import logging
import tempfile
from pathlib import Path

# Import parser dari rpz2cdb.py
# Cari rpz2cdb di: direktori yang sama, atau lib directory
_here = os.path.dirname(os.path.abspath(__file__))
for _p in [_here, "/usr/local/lib/internet-sehat"]:
    if os.path.exists(os.path.join(_p, "rpz2cdb.py")):
        sys.path.insert(0, _p)
        break
from rpz2cdb import convert, parse_line, is_ip_domain

logging.basicConfig(
    level=logging.INFO,
    format="[%(levelname)s] %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger(__name__)

BLOCKLIST_DIR = "/opt/blocklist"
CDB_FILE      = f"{BLOCKLIST_DIR}/blocklist.cdb"
WILDCARD_FILE = f"{BLOCKLIST_DIR}/wildcards.txt"
EXACT_FILE    = f"{BLOCKLIST_DIR}/exact-domains.txt"
SERIAL_FILE   = f"{BLOCKLIST_DIR}/.serial"


# ---------------------------------------------------------------
# Serial management
# ---------------------------------------------------------------

def get_remote_serial(server: str, zone: str) -> int | None:
    result = subprocess.run(
        ["dig", f"@{server}", zone, "SOA", "+short", "+time=10", "+tries=2"],
        capture_output=True, text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return None
    parts = result.stdout.strip().split()
    # SOA format: ns. email. serial refresh retry expire minimum
    return int(parts[2]) if len(parts) >= 3 else None


def get_local_serial() -> int:
    try:
        return int(Path(SERIAL_FILE).read_text().strip())
    except (FileNotFoundError, ValueError):
        return 0


def save_serial(serial: int):
    Path(SERIAL_FILE).write_text(str(serial))


# ---------------------------------------------------------------
# AXFR — full zone transfer
# ---------------------------------------------------------------

def run_axfr(server: str, zone: str):
    """Full AXFR → rebuild CDB dari awal. Streaming tanpa buffer RAM."""
    log.info(f"AXFR dari {server} (zona: {zone}) ...")

    proc = subprocess.Popen(
        ["dig", f"@{server}", zone, "AXFR", "+time=600", "+tries=1"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    try:
        convert(
            proc.stdout,
            cdb_path        = CDB_FILE,
            wildcard_path   = WILDCARD_FILE,
            zone            = zone,
            exact_list_path = EXACT_FILE,
        )
    finally:
        proc.stdout.close()
        proc.wait()

    stderr_out = proc.stderr.read()
    if proc.returncode != 0:
        raise RuntimeError(f"AXFR gagal (rc={proc.returncode}): {stderr_out.strip()}")
    if "Transfer failed" in stderr_out:
        raise RuntimeError(f"AXFR transfer failed: {stderr_out.strip()}")


# ---------------------------------------------------------------
# IXFR — incremental zone transfer
# ---------------------------------------------------------------

def run_ixfr(server: str, zone: str, local_serial: int) -> tuple[bool, int | None]:
    """
    Coba IXFR. Return (success, new_serial).
    Kalau server kirim AXFR fallback atau error → return (False, None).
    """
    log.info(f"IXFR dari {server} (serial {local_serial} → ?) ...")

    # Streaming: parse output dig baris per baris, jangan buffer seluruh
    # delta ke RAM (delta besar = OOM, bisa kill dnsdist → DNS mati).
    proc = subprocess.Popen(
        ["dig", f"@{server}", zone, f"IXFR={local_serial}",
         "+time=120", "+tries=1", "+noall", "+answer"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    try:
        adds, deletes, is_axfr_fallback, new_serial = _parse_ixfr_output(
            proc.stdout, zone
        )
    finally:
        proc.stdout.close()
        proc.wait()

    stderr_out = proc.stderr.read()
    if proc.returncode != 0:
        log.warning(f"IXFR: error (rc={proc.returncode}): {stderr_out.strip()}, "
                    "fallback ke AXFR")
        return False, None

    if is_axfr_fallback:
        log.info("Server mengirim AXFR fallback (serial terlalu lama), lanjut AXFR")
        return False, None

    if new_serial is None:
        log.warning("IXFR: tidak bisa baca serial dari respons, fallback ke AXFR")
        return False, None

    if not adds and not deletes:
        log.info("IXFR: tidak ada perubahan")
        return True, new_serial

    log.info(f"IXFR delta: +{len(adds)} tambah, -{len(deletes)} hapus")
    _apply_delta(adds, deletes)
    return True, new_serial


def _parse_ixfr_output(lines, zone: str) -> tuple:
    """
    Parse output dig IXFR (flat FQDN format, tanpa $ORIGIN).
    `lines` boleh string atau iterable baris (mis. proc.stdout) — diproses
    streaming agar tidak menahan seluruh output di RAM.

    IXFR structure:
      SOA(new) → SOA(old) → [deletes] → SOA(new) → [adds] → SOA(new)

    Return: (adds, deletes, is_axfr_fallback, new_serial)
    """
    zone_suffix = f".{zone}."
    zone_apex   = f"{zone}."

    adds    = []  # list of (domain, is_wildcard)
    deletes = []

    # State machine
    # INIT → GOT_OUTER_SOA → IN_DELETE → IN_ADD → DONE
    state      = "INIT"
    new_serial = None
    soa_count  = 0

    if isinstance(lines, str):
        lines = lines.splitlines()

    for raw in lines:
        line = raw.strip()
        if not line or line.startswith(";"):
            continue

        parts = line.split()
        if len(parts) < 4:
            continue

        owner = parts[0].lower()
        rtype = parts[3].upper() if len(parts) > 3 else ""

        # --- SOA records menandai batas section ---
        is_zone_soa = rtype == "SOA" and (
            owner == zone_apex or owner.rstrip(".") == zone.lower()
        )

        if is_zone_soa:
            soa_count += 1
            serial = int(parts[6]) if len(parts) > 6 else 0

            if state == "INIT":
                new_serial = serial
                state = "GOT_OUTER_SOA"
            elif state == "GOT_OUTER_SOA":
                if serial == new_serial:
                    # Hanya 2 SOA dengan serial sama → no change atau AXFR tanpa record
                    state = "NO_CHANGE"
                else:
                    # SOA lama → masuk section DELETE
                    state = "IN_DELETE"
            elif state == "IN_DELETE":
                # SOA baru → akhir delete, mulai ADD
                state = "IN_ADD"
            elif state == "IN_ADD":
                # SOA baru lagi → akhir delta cycle
                # Bisa ada multiple cycles (jarang), tapi kita handle sebagai DONE
                state = "DONE"
                break
            continue

        # --- Parse record biasa ---
        if state in ("IN_DELETE", "IN_ADD"):
            result = parse_line(line, zone_suffix, "lamanlabuh")
            if result:
                domain, is_wildcard = result
                if state == "IN_DELETE":
                    deletes.append((domain, is_wildcard))
                else:
                    adds.append((domain, is_wildcard))

    # Kalau hanya dapat 1 SOA → server kirim AXFR fallback (dimulai SOA, bukan SOA pair)
    # Atau state masih GOT_OUTER_SOA → tidak ada delta structure
    is_axfr_fallback = state in ("GOT_OUTER_SOA",)

    return adds, deletes, is_axfr_fallback, new_serial


def _update_text_file(file_path: str, adds: list, deletes: set):
    """Update text list: hapus entries yang ada di deletes, tambahkan entries dari adds."""
    tmp_fd, tmp_path = tempfile.mkstemp(dir=BLOCKLIST_DIR, suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w") as tmp_f:
            if os.path.exists(file_path):
                with open(file_path) as src:
                    for line in src:
                        domain = line.strip()
                        if domain and domain not in deletes:
                            tmp_f.write(domain + "\n")
            for domain in adds:
                tmp_f.write(domain + "\n")
        os.replace(tmp_path, file_path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def _apply_delta(adds: list, deletes: list):
    """
    Apply IXFR delta ke exact-domains.txt dan wildcards.txt → rebuild CDB.
    Tidak load semua domain ke RAM — streaming line by line.
    """
    exact_deletes = {d for d, w in deletes if not w}
    exact_adds    = [d for d, w in adds if not w]
    wc_deletes    = {d for d, w in deletes if w}
    wc_adds       = [d for d, w in adds if w]

    if not exact_deletes and not exact_adds and not wc_deletes and not wc_adds:
        log.info("Tidak ada perubahan pada domains")
        return

    if exact_deletes or exact_adds:
        _update_text_file(EXACT_FILE, exact_adds, exact_deletes)
        log.info(f"exact-domains.txt: +{len(exact_adds)} -{len(exact_deletes)}")

    if wc_deletes or wc_adds:
        _update_text_file(WILDCARD_FILE, wc_adds, wc_deletes)
        log.info(f"wildcards.txt: +{len(wc_adds)} -{len(wc_deletes)}")

    # Rebuild CDB dari kedua list sekaligus agar wildcard apex masuk CDB
    _rebuild_cdb_from_list([EXACT_FILE, WILDCARD_FILE], CDB_FILE)


def _rebuild_cdb_from_list(list_paths, cdb_path: str):
    """Rebuild CDB dari satu atau lebih text list (satu domain per baris)."""
    if isinstance(list_paths, str):
        list_paths = [list_paths]

    cdb_tmp = cdb_path + ".tmp"
    proc = subprocess.Popen(
        ["cdbmake", cdb_path, cdb_tmp],
        stdin=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    try:
        for list_path in list_paths:
            if not os.path.exists(list_path):
                continue
            with open(list_path) as f:
                for line in f:
                    domain = line.strip()
                    if domain:
                        proc.stdin.write(f"+{len(domain)},1:{domain}->1\n".encode())
        proc.stdin.write(b"\n")
        proc.stdin.close()
        proc.wait()
        if proc.returncode != 0:
            stderr = proc.stderr.read().decode()
            raise RuntimeError(f"cdbmake gagal: {stderr}")
    except Exception:
        proc.kill()
        raise

    size_mb = os.path.getsize(cdb_path) / 1024 / 1024
    log.info(f"CDB rebuilt: {cdb_path} ({size_mb:.1f} MB)")


# ---------------------------------------------------------------
# Main
# ---------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Sync Komdigi RPZ → CDB via IXFR/AXFR"
    )
    parser.add_argument("--server",  required=True, help="IP RPZ server Komdigi")
    parser.add_argument("--zone",    default="trustpositifkominfo", help="Nama zone RPZ")
    parser.add_argument("--force",   action="store_true",
                        help="Paksa AXFR meski serial sama")
    args = parser.parse_args()

    os.makedirs(BLOCKLIST_DIR, exist_ok=True)

    # 1. Cek serial
    log.info(f"Mengecek SOA serial dari {args.server}...")
    remote_serial = get_remote_serial(args.server, args.zone)
    if remote_serial is None:
        log.error("Gagal mendapatkan SOA serial dari server")
        sys.exit(1)

    local_serial = get_local_serial()
    log.info(f"Serial: lokal={local_serial}  remote={remote_serial}")

    if remote_serial == local_serial and not args.force:
        log.info("Tidak ada perubahan, skip.")
        return

    new_serial = None

    # 2. Coba IXFR kalau ada serial lokal
    if local_serial > 0 and not args.force:
        success, new_serial = run_ixfr(args.server, args.zone, local_serial)
        if success:
            save_serial(new_serial)
            log.info(f"Sync selesai via IXFR. Serial: {local_serial} → {new_serial}")
            return

    # 3. AXFR (first run atau IXFR fallback)
    try:
        run_axfr(args.server, args.zone)
    except RuntimeError as e:
        log.error(f"AXFR gagal: {e}")
        log.error("Serial TIDAK disimpan — sync berikutnya akan retry AXFR.")
        sys.exit(1)
    save_serial(remote_serial)
    log.info(f"Sync selesai via AXFR. Serial: {remote_serial}")


if __name__ == "__main__":
    main()
