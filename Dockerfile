# Debian, not Alpine: bw and bwdc are glibc binaries.
#
# Pinned to the stable branch rather than :latest, so a rebuild is
# reproducible and a branch bump is a reviewable change. Security patches
# within the branch still arrive: rebuild-on-updates.yml rebuilds when the
# base image or any installed package falls behind.
FROM debian:trixie-slim

# Bitwarden CLI and Directory Connector, from their GitHub releases. The
# checksums are the ones GitHub publishes for each asset: a release that is
# replaced or tampered with after the fact fails the build.
ARG BW_VERSION=2026.10.1
ARG BW_SHA256=eb09c3715291c21cf744819b873a255c1247b1b8b45bae138621a644ec7ad8f5
ARG BWDC_VERSION=2026.10.0
ARG BWDC_SHA256=b46e723804ab1ab3a8b3cb34cd5901acb44a570d94cdc5176e80ebde086dd994

# apt-get upgrade first: the base image's own packages can lag the archive,
# and the nightly rebuild only helps if it brings them up to date too.
# libatomic1: bwdc does not start without it. curl and jq: the sync script.
RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends ca-certificates curl jq libatomic1 tini unzip; \
    curl -fsSL --retry 5 -o /tmp/bw.zip \
      "https://github.com/bitwarden/clients/releases/download/cli-v${BW_VERSION}/bw-linux-${BW_VERSION}.zip"; \
    echo "${BW_SHA256}  /tmp/bw.zip" | sha256sum -c -; \
    curl -fsSL --retry 5 -o /tmp/bwdc.zip \
      "https://github.com/bitwarden/directory-connector/releases/download/v${BWDC_VERSION}/bwdc-linux-${BWDC_VERSION}.zip"; \
    echo "${BWDC_SHA256}  /tmp/bwdc.zip" | sha256sum -c -; \
    mkdir -p /opt/bw /opt/bwdc; \
    unzip -q /tmp/bw.zip -d /opt/bw; \
    unzip -q /tmp/bwdc.zip -d /opt/bwdc; \
    chmod 755 /opt/bw/bw /opt/bwdc/bwdc; \
    rm -f /tmp/bw.zip /tmp/bwdc.zip; \
    apt-get purge -y unzip; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*; \
    useradd --uid 1500 --user-group --home-dir /data --no-create-home --shell /usr/sbin/nologin orgsync; \
    mkdir -p /data && chown orgsync:orgsync /data

COPY scripts/orgsync.sh /usr/local/bin/orgsync.sh

ENV HOME=/data
USER 1500
WORKDIR /data
VOLUME /data

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/orgsync.sh"]

# The loop touches this after every pass. Ten minutes covers a slow
# directory sync on top of the one-minute pass.
HEALTHCHECK --interval=60s --timeout=10s --start-period=5m \
  CMD find /data/.heartbeat -mmin -10 | grep -q . || exit 1
