#!/usr/bin/env bash
set -u
. /tests/lib-assert.sh
FIX=/tests/fixtures
WORK=$(mktemp -d)
export ORGSYNC_DATA="$WORK/data"

printf '\nbwgc_orgsync tests\n\n'
for case_file in /tests/cases/*.sh; do
	name=$(basename "$case_file" .sh)
	if [ -n "${FILTER:-}" ]; then
		case "$name" in *"$FILTER"*) ;; *) continue ;; esac
	fi
	printf '%s\n' "$name"
	# Each case starts from a fresh copy of the script's state.
	rm -rf "$ORGSYNC_DATA"; mkdir -p "$ORGSYNC_DATA"
	# shellcheck disable=SC1091
	ORGSYNC_SOURCE_ONLY=1 . /orgsync.sh
	# shellcheck disable=SC1090
	. "$case_file"
	printf '\n'
done
rm -rf "$WORK"
printf 'ran %d assertions, %d failed\n\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
