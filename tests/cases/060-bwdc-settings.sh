# The Workspace directory and the sync options are written into bwdc's state,
# and survive bwdc saving that state again.
GSUITE_DOMAIN=27z.fr GSUITE_ADMIN=admin@27z.fr USER_FILTER="exclude:noreply@27z.fr,contact@27z.fr"
DIRECTORY_INTERVAL=900 REMOVE_DISABLED=true OVERWRITE_EXISTING=true
D="$BITWARDENCLI_CONNECTOR_APPDATA_DIR"; mkdir -p "$D"
/opt/bwdc/bwdc config server http://bitwarden:80 >/dev/null 2>&1
/opt/bwdc/bwdc config directory 2 >/dev/null 2>&1
bwdc_settings "$FIX/google-key.json" < "$D/data.json" > "$D/new.json" && mv "$D/new.json" "$D/data.json"
check() { # label
	assert_eq "$(jq -r '.directoryType' "$D/data.json")" "2" "$1: directory is Google Workspace"
	assert_eq "$(jq -r '.directoryGsuite | [.clientEmail, .domain, .adminUser] | join(" ")' "$D/data.json")" \
		"bwdc-sync@test.iam.gserviceaccount.com 27z.fr admin@27z.fr" "$1: service account, domain and admin"
	assert_contains "$(jq -r '.directoryGsuite.privateKey' "$D/data.json")" "BEGIN PRIVATE KEY" "$1: the private key"
	assert_eq "$(jq -c '.sync | [.users, .groups, .removeDisabled, .overwriteExisting, .inviteUsersAfterProvisioning, .interval]' "$D/data.json")" \
		"[true,false,true,true,true,15]" "$1: users only, removals, invitations, 15 min"
	assert_eq "$(jq -r '.sync.userFilter' "$D/data.json")" "exclude:noreply@27z.fr,contact@27z.fr" "$1: the user filter"
	assert_eq "$(jq -r '.environmentUrls.base' "$D/data.json")" "http://bitwarden:80" "$1: the server is kept"
}
check "written"
# bwdc loads and rewrites its whole state on any config change.
/opt/bwdc/bwdc config server http://bitwarden:80 >/dev/null 2>&1
check "after bwdc rewrote it"
