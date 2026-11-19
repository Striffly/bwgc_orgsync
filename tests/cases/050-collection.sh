# Every confirmed member gets the collection; existing access is kept as is.
IN=$(jq -n --slurpfile m "$FIX/members.json" --slurpfile c "$FIX/collection.json" '{members: $m[0], collection: $c[0]}')
OUT=$(collection_update true <<< "$IN")
assert_eq "$(jq -r '[.users[].id] | join(" ")' <<< "$OUT")" \
	"11111111-1111-1111-1111-111111111111 22222222-2222-2222-2222-222222222222 66666666-6666-6666-6666-666666666666" \
	"confirmed members are added after those already there"
assert_eq "$(jq -c '.users[0]' <<< "$OUT")" '{"id":"11111111-1111-1111-1111-111111111111","readOnly":false,"hidePasswords":false,"manage":true}' \
	"an existing member's access is not changed"
assert_eq "$(jq -c '.users[2]' <<< "$OUT")" '{"id":"66666666-6666-6666-6666-666666666666","readOnly":true,"hidePasswords":false,"manage":false}' \
	"a new member gets read-only access"
assert_eq "$(jq -c '.groups' <<< "$OUT")" "$(jq -c '.groups' "$FIX/collection.json")" "groups are kept"
assert_eq "$(jq -r '.name, .organizationId' <<< "$OUT" | tr '\n' ' ')" "Partage 27Z aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa " "name and organisation are sent back"
assert_eq "$(jq -c '.users[2].readOnly' <<< "$(collection_update false <<< "$IN")")" "false" "ORGSYNC_COLLECTION_READONLY=false gives edit access"

DONE=$(jq -c --argjson u "$(jq -c '.users' <<< "$OUT")" '.collection.users = $u' <<< "$IN")
assert_eq "$(collection_update true <<< "$DONE")" "" "nothing to send once everyone has it"
