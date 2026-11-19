# Debian, not Alpine: bw and bwdc are glibc binaries.
#
# Pinned to the stable branch rather than :latest, so a rebuild is
# reproducible and a branch bump is a reviewable change. Security patches
# within the branch still arrive: rebuild-on-updates.yml rebuilds when the
# base image or any installed package falls behind.
FROM debian:trixie-slim

# bw and bwdc are not pinned: every build takes the newest release of each,
# and build-docker-image.yml rebuilds weekly so new releases arrive on their
# own. The test suite runs against the built image before it is published,
# and bitwarden_gcloud's autoupdate holds every new image in quarantine for
# three days before installing it.
#
# apt-get upgrade first: the base image's own packages can lag the archive.
# libatomic1: bwdc does not start without it. curl and jq: the sync script.
RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends ca-certificates curl jq libatomic1 tini unzip; \
    # Bitwarden's own download link redirects to the newest CLI release.
    curl -fsSL --retry 5 -o /tmp/bw.zip "https://vault.bitwarden.com/download/?app=cli&platform=linux"; \
    # GitHub redirects releases/latest to the newest release's tag.
    BWDC_TAG=$(curl -fsSI --retry 5 https://github.com/bitwarden/directory-connector/releases/latest \
      | sed -n 's|^[Ll]ocation: .*/tag/\(v[0-9.]*\).*|\1|p'); \
    test -n "${BWDC_TAG}"; \
    curl -fsSL --retry 5 -o /tmp/bwdc.zip \
      "https://github.com/bitwarden/directory-connector/releases/download/${BWDC_TAG}/bwdc-linux-${BWDC_TAG#v}.zip"; \
    mkdir -p /opt/bw /opt/bwdc; \
    unzip -q /tmp/bw.zip -d /opt/bw; \
    unzip -q /tmp/bwdc.zip -d /opt/bwdc; \
    chmod 755 /opt/bw/bw /opt/bwdc/bwdc; \
    echo "bw $(/opt/bw/bw --version), bwdc $(/opt/bwdc/bwdc --version)" | tee /opt/versions; \
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
