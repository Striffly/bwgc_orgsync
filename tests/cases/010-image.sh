# The image carries the pinned tools and runs as its own user.
assert_ne "$(id -u)" "0" "the image does not run as root"
assert_contains "$(/opt/bw/bw --version 2>&1)" "2026.10.1" "bw is the pinned version"
assert_contains "$(/opt/bwdc/bwdc --version 2>&1)" "2026.10.0" "bwdc is the pinned version, libatomic present"
assert_file /usr/bin/tini "tini reaps bw serve and bwdc"
for t in curl jq; do command -v "$t" >/dev/null && pass "$t is installed" || fail "$t is installed"; done
