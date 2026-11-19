assert_eq "$(org_id_from_client_id organization.aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa)" \
	"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" "the organisation id comes from its API key's client_id"
org_id_from_client_id user.abc >/dev/null; assert_ne "$?" "0" "a user API key is refused"
