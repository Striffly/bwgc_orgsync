# Only members who accepted, with the plain User role, are confirmed.
IDS=$(members_to_confirm < "$FIX/members.json" | tr '\n' ' ')
assert_eq "$IDS" "33333333-3333-3333-3333-333333333333 88888888-8888-8888-8888-888888888888 " "accepted users are picked"
assert_not_contains "$IDS" "55555555" "an accepted admin is left to a human"
assert_not_contains "$IDS" "44444444" "an invited member who has not accepted is not"
assert_not_contains "$IDS" "77777777" "a revoked member is not"
assert_eq "$(echo '[]' | members_to_confirm)" "" "an empty organisation confirms nobody"
