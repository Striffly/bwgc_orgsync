# Secrets are read literally: a password may hold any character, and nothing
# in the file is ever evaluated by the shell.
S="$ORGSYNC_DATA/secrets.env"
{
	printf '# comment\n\n'
	printf 'ROBOT_CLIENT_ID=user.abc\r\n'
	printf 'ROBOT_CLIENT_SECRET=s3cr3t\n'
	printf '%s\n' 'ROBOT_PASSWORD= a$b"c'"'"'d\e=f `id` $(id) '
	printf 'ORG_CLIENT_ID=organization.aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\n'
	printf 'ORG_CLIENT_SECRET=orgsecret\n'
	printf 'EVIL=$(touch %s/pwned)\n' "$ORGSYNC_DATA"
} > "$S"
read_secrets "$S" >/dev/null; assert_status "$?" 0 "a complete file is accepted"
assert_eq "$ROBOT_PASSWORD" ' a$b"c'"'"'d\e=f `id` $(id) ' "the password is kept byte for byte"
assert_eq "$ROBOT_CLIENT_ID" "user.abc" "a CRLF line ending is stripped"
assert_no_file "$ORGSYNC_DATA/pwned" "an unknown key is never evaluated"
assert_contains "$(read_secrets "$S")" "ignoring unknown key 'EVIL'" "and it is reported"

grep -v '^ORG_CLIENT_SECRET=' "$S" > "$S.2"
ORG_CLIENT_SECRET=""
OUT=$(read_secrets "$S.2"); assert_ne "$?" "0" "a missing key is refused"
assert_contains "$OUT" "ORG_CLIENT_SECRET" "and named"
OUT=$(read_secrets "$ORGSYNC_DATA/nope"); assert_ne "$?" "0" "an unreadable file is refused"
