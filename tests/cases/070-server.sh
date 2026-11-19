# bw refuses a plain http:// server, so the script refuses to start with one
# rather than failing later with "Insecure URL not allowed".
OUT=$(ORGSYNC_SERVER=http://bitwarden:80 ORGSYNC_SOURCE_ONLY= ORGSYNC_DATA="$ORGSYNC_DATA" timeout 20 bash /orgsync.sh 2>&1); RC=$?
assert_eq "$RC" "1" "an http:// server is refused at start"
assert_contains "$OUT" "must be the vault's https:// address" "and the log says why"
OUT=$(ORGSYNC_SERVER= ORGSYNC_SOURCE_ONLY= ORGSYNC_DATA="$ORGSYNC_DATA" timeout 20 bash /orgsync.sh 2>&1); RC=$?
assert_eq "$RC" "1" "an unset server is refused too"
