# The collection is found by id, which survives a rename, or by name.
L='{"success":true,"data":{"data":[{"id":"aaaa","name":"27Z - Identifiants partagés"},{"id":"bbbb","name":"27Z - Identifiants d'"'"'administration"}]}}'
assert_eq "$(collection_id aaaa <<< "$L")" "aaaa" "found by id"
assert_eq "$(collection_id "27Z - Identifiants partagés" <<< "$L")" "aaaa" "found by name, accents and spaces included"
assert_eq "$(collection_id "Partage 27Z" <<< "$L")" "" "an unknown name finds nothing"
