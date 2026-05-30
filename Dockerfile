FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Packages yang dibutuhkan install.sh + dashboard
RUN apt-get update && apt-get install -y \
    dnsdist \
    freecdb \
    dnsutils \
    python3 \
    curl \
    whiptail \
    cron \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Fake systemctl supaya install.sh berjalan tanpa modifikasi
COPY docker/systemctl-fake.sh /usr/local/bin/systemctl
RUN chmod +x /usr/local/bin/systemctl

# Project files — install.sh akan copy dns/ ke system path saat dijalankan
WORKDIR /opt/internet-sehat
COPY install.sh .
COPY dns/ dns/

# Build dashboard (standalone untuk container)
COPY dashboard/ dashboard/
RUN cd dashboard && npm ci && npm run build \
    && cp -r .next/standalone /opt/dashboard \
    && cp -r .next/static /opt/dashboard/.next/static \
    && cp -r public /opt/dashboard/public

# Symlinks untuk dns scripts — install.sh akan overwrite ke LIB_DIR, tapi
# ini cukup untuk entrypoint auto-configure tanpa install.sh terlebih dahulu
RUN chmod +x /opt/internet-sehat/dns/rpz2cdb.py \
             /opt/internet-sehat/dns/rpz-sync.py \
             /opt/internet-sehat/dns/test.sh && \
    ln -sf /opt/internet-sehat/dns/rpz2cdb.py  /usr/local/bin/rpz2cdb  && \
    ln -sf /opt/internet-sehat/dns/rpz-sync.py /usr/local/bin/rpz-sync && \
    ln -sf /opt/internet-sehat/dns/test.sh      /usr/local/bin/dns-test

# Direktori sistem yang dibutuhkan
RUN mkdir -p /opt/blocklist /var/log/dnsdist /etc/dnsdist

COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/reload-dashboard.sh /usr/local/bin/reload-dashboard
RUN chmod +x /entrypoint.sh /usr/local/bin/reload-dashboard

EXPOSE 53/udp 53/tcp 5199/tcp 8083/tcp 3000/tcp

ENTRYPOINT ["/entrypoint.sh"]
