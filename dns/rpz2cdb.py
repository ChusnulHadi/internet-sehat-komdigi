#!/usr/bin/env python3
"""
rpz2cdb.py
Convert Komdigi RPZ zone master file ke:
  1. CDB file       → exact match di dnsdist
  2. Wildcard file  → SuffixMatchNode di dnsdist (subdomain blocking)

Format input: zone master file dengan $ORIGIN directive (output dari dig AXFR
atau file zone BIND slave).

Usage:
  # Dari file
  python3 rpz2cdb.py db.trustpositifkominfo

  # Pipe dari dig langsung
  dig @<server> trustpositifkominfo AXFR | python3 rpz2cdb.py -

  # Custom output
  python3 rpz2cdb.py db.trustpositifkominfo \\
      --cdb /opt/blocklist/blocklist.cdb \\
      --wildcard /opt/blocklist/wildcards.txt

  # Custom zone name
  python3 rpz2cdb.py db.trustpositifkominfo --zone trustpositifkominfo
"""

import sys
import os
import argparse
import subprocess
import logging

logging.basicConfig(
    level=logging.INFO,
    format="[%(levelname)s] %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger(__name__)

BLOCK_TARGET_PREFIX = "lamanlabuh"


def is_ip_domain(domain: str) -> bool:
    """
    Cek apakah domain adalah IP-based RPZ record (reversed IP).
    Contoh: 13.251.79.1 → semua label adalah angka → skip.
    """
    labels = domain.split(".")
    return all(lbl.isdigit() for lbl in labels if lbl)


def parse_line(line: str, zone_suffix: str, block_target_prefix: str = BLOCK_TARGET_PREFIX):
    """
    Parse satu baris flat FQDN format (output dig AXFR/IXFR tanpa $ORIGIN).
    Dipakai oleh rpz-sync untuk parsing IXFR delta.

    Format: <fqdn-owner> <ttl> IN CNAME <rdata>
    Contoh: pornhub.com.trustpositifkominfo. 3600 IN CNAME lamanlabuh.aduankonten.id.

    Return: (domain, is_wildcard) atau None kalau bukan record yang relevan.
    """
    line = line.strip()
    if not line or line.startswith(";") or line.startswith("$"):
        return None

    parts = line.split()
    if len(parts) < 5:
        return None

    owner = parts[0].lower()
    if not owner.endswith("."):
        return None  # bukan FQDN absolut

    # Cari posisi CNAME
    try:
        cname_idx = next(i for i, p in enumerate(parts) if p.upper() == "CNAME")
    except StopIteration:
        return None

    rdata = parts[cname_idx + 1].lower() if cname_idx + 1 < len(parts) else ""
    if not rdata.startswith(block_target_prefix):
        return None

    if not owner.endswith(zone_suffix):
        return None

    domain = owner[: -len(zone_suffix)].rstrip(".")
    if not domain:
        return None

    is_wildcard = domain.startswith("*.")
    if is_wildcard:
        domain = domain[2:]

    if not domain or is_ip_domain(domain):
        return None

    return (domain, is_wildcard)


def convert(input_stream, cdb_path: str, wildcard_path: str, zone: str,
            exact_list_path: str = None):
    """
    Parse zone master file dengan $ORIGIN tracking.
    Fully streaming — tidak load domain ke RAM.

    Format yang dihandle:
      $ORIGIN netlify.app.trustpositifkominfo.
      agam188-bo    CNAME  lamanlabuh.aduankonten.id.   ← exact
      $ORIGIN agam188-bo.netlify.app.trustpositifkominfo.
      *             CNAME  lamanlabuh.aduankonten.id.   ← wildcard
    """
    zone_suffix = f".{zone}."           # ".trustpositifkominfo."
    zone_apex   = f"{zone}."            # "trustpositifkominfo."

    os.makedirs(os.path.dirname(os.path.abspath(cdb_path)), exist_ok=True)

    if subprocess.run(["which", "cdbmake"], capture_output=True).returncode != 0:
        log.error("cdbmake tidak ditemukan. Install: sudo apt install freecdb")
        sys.exit(1)

    log.info(f"Zone         : {zone_apex}")
    log.info(f"Zone suffix  : {zone_suffix}")
    log.info(f"CDB output   : {cdb_path}")
    log.info(f"Wildcard out : {wildcard_path}")

    cdb_new = cdb_path + ".new"
    cdb_tmp = cdb_path + ".tmp"
    wc_new  = wildcard_path + ".new"
    cdbmake = subprocess.Popen(
        ["cdbmake", cdb_new, cdb_tmp],
        stdin=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    exact_count    = 0
    wildcard_count = 0
    ip_skip_count  = 0
    line_count     = 0
    current_origin = ""   # $ORIGIN aktif saat ini

    try:
        el_file = open(exact_list_path, "w") if exact_list_path else None
        with open(wc_new, "w") as wc_file:
            for raw_line in input_stream:
                line_count += 1
                line = raw_line.strip()

                # --- $ORIGIN ---
                if line.startswith("$ORIGIN"):
                    parts = line.split()
                    if len(parts) >= 2:
                        current_origin = parts[1].lower()
                        if not current_origin.endswith("."):
                            current_origin += "."
                    continue

                # --- Skip komentar, $TTL, baris kosong, SOA, NS ---
                if (
                    not line
                    or line.startswith(";")
                    or line.startswith("$")
                    or "SOA" in line
                    or line.startswith("NS")
                ):
                    continue

                # --- Parse record ---
                parts = line.split()
                if len(parts) < 3:
                    continue

                # Cari posisi CNAME (bisa ada TTL/class di tengah)
                try:
                    cname_idx = next(
                        i for i, p in enumerate(parts) if p.upper() == "CNAME"
                    )
                except StopIteration:
                    continue

                rdata = parts[cname_idx + 1].lower() if cname_idx + 1 < len(parts) else ""
                if not rdata.startswith(BLOCK_TARGET_PREFIX):
                    continue

                label = parts[0].lower()

                # Resolve full domain name
                if label.endswith("."):
                    # Absolute name (FQDN)
                    full_name = label
                elif label == "@":
                    # Zone apex — skip
                    continue
                else:
                    # Relative → prepend ke $ORIGIN
                    if not current_origin:
                        continue
                    full_name = label + "." + current_origin

                # Harus merupakan subdomain dari zone kita
                if not full_name.endswith(zone_suffix) and full_name != zone_apex:
                    continue

                # Strip zone suffix → dapat domain yang diblokir
                if full_name.endswith(zone_suffix):
                    domain = full_name[: -len(zone_suffix)]
                else:
                    continue

                if not domain:
                    continue

                # Deteksi wildcard
                is_wildcard = domain.startswith("*.")
                if is_wildcard:
                    domain = domain[2:]  # strip "*."

                # Skip IP-based records
                if is_ip_domain(domain):
                    ip_skip_count += 1
                    continue

                if is_wildcard:
                    wc_file.write(domain + "\n")
                    wildcard_count += 1
                else:
                    if el_file:
                        el_file.write(domain + "\n")
                    exact_count += 1

                # Semua domain (exact & wildcard) masuk CDB agar
                # parentInBlocklist di dnsdist bisa match subdomain wildcard.
                record = f"+{len(domain)},1:{domain}->1\n"
                cdbmake.stdin.write(record.encode())

                if line_count % 1_000_000 == 0:
                    log.info(
                        f"  {line_count:,} baris | "
                        f"exact={exact_count:,} wildcard={wildcard_count:,} "
                        f"ip_skip={ip_skip_count:,}"
                    )

        # Terminasi CDB
        cdbmake.stdin.write(b"\n")
        cdbmake.stdin.close()
        cdbmake.wait()

        if cdbmake.returncode != 0:
            stderr = cdbmake.stderr.read() if cdbmake.stderr else b""
            raise RuntimeError(f"cdbmake gagal: {stderr.decode()}")

    except Exception:
        cdbmake.kill()
        raise
    finally:
        if el_file:
            el_file.close()

    log.info("=" * 55)
    log.info(f"Selesai! ({line_count:,} baris diproses)")

    if exact_count == 0 and wildcard_count == 0:
        # Hapus file temp agar tidak mengotori disk
        for f in (cdb_new, wc_new):
            try:
                os.unlink(f)
            except OSError:
                pass
        msg = (
            f"Hanya {line_count} baris diterima — kemungkinan AXFR ditolak atau "
            "server tidak memberikan answer."
            if line_count <= 10
            else "Tidak ada domain yang berhasil diproses — periksa format zone / prefix CNAME."
        )
        log.warning(msg)
        raise RuntimeError("Blocklist kosong — sync dibatalkan, CDB lama tidak ditimpa")

    # Atomically replace hanya jika ada data
    os.replace(cdb_new, cdb_path)
    os.replace(wc_new, wildcard_path)

    cdb_size = os.path.getsize(cdb_path) / 1024 / 1024
    wc_size  = os.path.getsize(wildcard_path) / 1024 / 1024

    log.info(f"  Exact domains (CDB)  : {exact_count:,}  →  {cdb_size:.1f} MB")
    log.info(f"  Wildcard domains     : {wildcard_count:,}  →  {wc_size:.1f} MB")
    log.info(f"  IP records (skip)    : {ip_skip_count:,}")
    log.info("=" * 55)


def main():
    parser = argparse.ArgumentParser(
        description="Convert Komdigi RPZ zone file ke CDB + wildcard list"
    )
    parser.add_argument(
        "input",
        nargs="?",
        default="-",
        help="Zone file path, atau '-' untuk stdin (default: stdin)",
    )
    parser.add_argument(
        "--cdb",
        default="/opt/blocklist/blocklist.cdb",
        help="Output CDB path (default: /opt/blocklist/blocklist.cdb)",
    )
    parser.add_argument(
        "--wildcard",
        default="/opt/blocklist/wildcards.txt",
        help="Output wildcard domains file (default: /opt/blocklist/wildcards.txt)",
    )
    parser.add_argument(
        "--zone",
        default="trustpositifkominfo",
        help="Nama zone RPZ tanpa trailing dot (default: trustpositifkominfo)",
    )
    args = parser.parse_args()

    if args.input == "-":
        log.info("Membaca dari stdin...")
        convert(sys.stdin, args.cdb, args.wildcard, args.zone)
    else:
        if not os.path.exists(args.input):
            log.error(f"File tidak ditemukan: {args.input}")
            sys.exit(1)
        log.info(f"Membaca dari: {args.input}")
        with open(args.input, "r", errors="replace") as f:
            convert(f, args.cdb, args.wildcard, args.zone)


if __name__ == "__main__":
    main()
