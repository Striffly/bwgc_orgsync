#!/usr/bin/env sh
#
# Test suite for bwgc_orgsync.
#
#   ./tests/run-tests.sh            build the image and run every case
#   ./tests/run-tests.sh secrets    run only cases matching "secrets"
#   BWGC_IMAGE=... ./tests/run-tests.sh
#
# Everything runs inside the image, as its own non-root user, with the script
# sourced in ORGSYNC_SOURCE_ONLY mode: the pure functions are exercised with
# fixtures, and the real bw and bwdc binaries are run offline. Nothing here
# talks to a Vaultwarden server or to Google.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FILTER="${1:-}"

if [ -n "${BWGC_IMAGE:-}" ]; then
	IMAGE="$BWGC_IMAGE"
	printf 'testing existing image: %s\n' "$IMAGE"
else
	IMAGE=bwgc_orgsync:test
	printf 'building %s\n' "$IMAGE"
	docker build -q -t "$IMAGE" "$ROOT" >/dev/null
fi

docker run --rm \
	-e FILTER="$FILTER" \
	-v "$ROOT/tests:/tests:ro" \
	-v "$ROOT/scripts/orgsync.sh:/orgsync.sh:ro" \
	--entrypoint bash "$IMAGE" /tests/in-container.sh
