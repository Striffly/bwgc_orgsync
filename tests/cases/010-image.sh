# The image carries both tools, records their versions, and runs as its own user.
assert_ne "$(id -u)" "0" "the image does not run as root"
V=$(cat /opt/versions 2>/dev/null)
assert_contains "$V" "bw " "the build recorded its versions: $V"
printf '%s' "$(/opt/bw/bw --version 2>&1)" | grep -qE '^[0-9]{4}\.[0-9]+\.[0-9]+$' && pass "bw runs" || fail "bw runs"
printf '%s' "$(/opt/bwdc/bwdc --version 2>&1)" | grep -qE '^[0-9]{4}\.[0-9]+\.[0-9]+$' && pass "bwdc runs, libatomic present" || fail "bwdc runs, libatomic present"
assert_file /usr/bin/tini "tini reaps bw serve and bwdc"
for t in curl jq; do command -v "$t" >/dev/null && pass "$t is installed" || fail "$t is installed"; done
