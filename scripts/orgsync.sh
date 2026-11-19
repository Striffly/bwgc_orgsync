#!/usr/bin/env bash
#
# bwgc_orgsync: keeps a Vaultwarden organisation in step with a Google
# Workspace directory, with no manual step.
#
#   every ORGSYNC_DIRECTORY_INTERVAL (15 min): bwdc syncs the directory's users
#     into the organisation: new addresses are invited, and, with
#     overwriteExisting, members who left the directory are removed.
#   every ORGSYNC_CONFIRM_INTERVAL (1 min): through an admin account (the
#     robot), members who accepted their invitation are confirmed, and every
#     confirmed member is given ORGSYNC_COLLECTION.
#
# Why a robot holding an admin's master password: confirming a member means
# encrypting the organisation key with that member's public key. Only an
# unlocked client of an owner or admin holds the organisation key; the server
# never does. So `bw serve` stays unlocked for the life of the container, and
# a curl every minute costs nothing, where starting bw costs ~2 s of CPU and
# bwdc ~12 s on an e2-micro.
#
# Secrets come from ORGSYNC_SECRETS, KEY=VALUE lines read literally (no quotes,
# no shell expansion), and the Google service account key from
# ORGSYNC_GOOGLE_KEY. Everything else is plain configuration, see README.md.
#
# ORGSYNC_SOURCE_ONLY=1 defines the functions and returns, for the tests.

set -uo pipefail

BW=${ORGSYNC_BW:-/opt/bw/bw}
BWDC=${ORGSYNC_BWDC:-/opt/bwdc/bwdc}
DATA=${ORGSYNC_DATA:-/data}
SECRETS=${ORGSYNC_SECRETS:-/secrets/orgsync.env}
GOOGLE_KEY=${ORGSYNC_GOOGLE_KEY:-/secrets/google-key.json}
# HTTPS only: bw refuses a plain http:// server ("Insecure URL not allowed").
# In bitwarden_gcloud it is https://$DOMAIN, resolved to the proxy container.
SERVER=${ORGSYNC_SERVER:-}
PORT=${ORGSYNC_PORT:-8087}

COLLECTION=${ORGSYNC_COLLECTION:-}
COLLECTION_READONLY=${ORGSYNC_COLLECTION_READONLY:-true}
CONFIRM_INTERVAL=${ORGSYNC_CONFIRM_INTERVAL:-60}
DIRECTORY_INTERVAL=${ORGSYNC_DIRECTORY_INTERVAL:-900}

DIRECTORY=${ORGSYNC_DIRECTORY:-gsuite}         # gsuite, or none for confirm-only
GSUITE_DOMAIN=${ORGSYNC_GSUITE_DOMAIN:-}
GSUITE_ADMIN=${ORGSYNC_GSUITE_ADMIN:-}
USER_FILTER=${ORGSYNC_USER_FILTER:-}
REMOVE_DISABLED=${ORGSYNC_REMOVE_DISABLED:-true}
OVERWRITE_EXISTING=${ORGSYNC_OVERWRITE_EXISTING:-false}

ALERT_TO=${ORGSYNC_ALERT_TO:-}
MAIL_FROM=${ORGSYNC_MAIL_FROM:-}
MAIL_RELAY=${ORGSYNC_MAIL_RELAY:-smtp://msmtpd:2500}

export BITWARDENCLI_APPDATA_DIR="${DATA}/bw"
export BITWARDENCLI_CONNECTOR_APPDATA_DIR="${DATA}/bwdc"
export BITWARDENCLI_CONNECTOR_PLAINTEXT_SECRETS=true
export BW_NOINTERACTION=true

ROBOT_CLIENT_ID="" ROBOT_CLIENT_SECRET="" ROBOT_PASSWORD="" ORG_CLIENT_ID="" ORG_CLIENT_SECRET=""
ORG_ID=""
SERVE_PID=""

log() { printf '%s orgsync: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# --- Pure functions (tested) -------------------------------------------------

# read_secrets FILE: sets the five known keys from KEY=VALUE lines. The value is
# everything after the first "=", byte for byte, so a password may hold any
# character. Unknown keys are reported, never evaluated.
read_secrets() {
	local line key value
	[ -r "$1" ] || { log "cannot read secrets file $1"; return 1; }
	while IFS= read -r line || [ -n "${line}" ]; do
		line=${line%$'\r'}
		case "${line}" in '' | '#'*) continue ;; esac
		key=${line%%=*}
		value=${line#*=}
		case "${key}" in
			ROBOT_CLIENT_ID | ROBOT_CLIENT_SECRET | ROBOT_PASSWORD | ORG_CLIENT_ID | ORG_CLIENT_SECRET)
				printf -v "${key}" '%s' "${value}" ;;
			*) log "ignoring unknown key '${key}' in $1" ;;
		esac
	done < "$1"
	local k missing=""
	for k in ROBOT_CLIENT_ID ROBOT_CLIENT_SECRET ROBOT_PASSWORD ORG_CLIENT_ID ORG_CLIENT_SECRET; do
		[ -n "${!k}" ] || missing="${missing} ${k}"
	done
	[ -z "${missing}" ] || { log "missing in $1:${missing}"; return 1; }
}

# org_id_from_client_id ID: "organization.<uuid>" -> "<uuid>".
org_id_from_client_id() {
	case "$1" in
		organization.*) printf '%s\n' "${1#organization.}" ;;
		*) return 1 ;;
	esac
}

# members_to_confirm: reads `bw list org-members` JSON on stdin, prints the id
# of every member who accepted (status 1) with the plain User role (type 2).
# An owner, admin or manager is never confirmed by a robot.
members_to_confirm() {
	jq -r '.[] | select(.status == 1 and .type == 2) | .id'
}

# collection_update READONLY: reads {"members": [...], "collection": {...}} on
# stdin and prints the collection with every confirmed member (status 2) added
# to its users, keeping existing groups and users as they are. Prints nothing
# when no member is missing, so the caller skips the request.
collection_update() {
	jq -c --argjson ro "$1" '
		.collection as $c
		| ([$c.users[]?.id]) as $have
		| [.members[] | select(.status == 2 and (.id as $i | $have | index($i) | not))
			| {id, readOnly: $ro, hidePasswords: false, manage: false}] as $add
		| if ($add | length) == 0 then empty
		  else {organizationId: $c.organizationId, name: $c.name, externalId: $c.externalId,
		        groups: ($c.groups // []), users: (($c.users // []) + $add)}
		  end'
}

# collection_id ID_OR_NAME: reads `bw list org-collections` output on stdin and
# prints the collection's id. An id is the stable choice: it survives renames.
collection_id() {
	jq -r --arg n "$1" '[.data.data[]? | select(.id == $n or .name == $n) | .id] | first // empty'
}

# bwdc_settings: reads bwdc's data.json on stdin and the Google key JSON from
# the file in $1, prints data.json with the Workspace directory and the sync
# options set. Only keys this script owns are touched.
bwdc_settings() {
	jq --slurpfile key "$1" \
		--arg domain "${GSUITE_DOMAIN}" --arg admin "${GSUITE_ADMIN}" \
		--arg filter "${USER_FILTER}" \
		--argjson interval "$(( DIRECTORY_INTERVAL / 60 ))" \
		--argjson removeDisabled "${REMOVE_DISABLED}" \
		--argjson overwrite "${OVERWRITE_EXISTING}" '
		.directoryType = 2
		| .directoryGsuite = ((.directoryGsuite // {}) + {
			clientEmail: $key[0].client_email, privateKey: $key[0].private_key,
			domain: $domain, adminUser: $admin, customer: ""})
		| .sync = ((.sync // {}) + {
			users: true, groups: false, interval: $interval,
			userFilter: $filter, groupFilter: "",
			removeDisabled: $removeDisabled, overwriteExisting: $overwrite,
			largeImport: false, inviteUsersAfterProvisioning: true})'
}

# --- Mail ---------------------------------------------------------------------

# alert SUBJECT BODY: one mail through the stack's relay. Failing to mail is
# logged, never fatal.
alert() {
	[ -n "${ALERT_TO}" ] && [ -n "${MAIL_FROM}" ] || { log "no ORGSYNC_ALERT_TO/ORGSYNC_MAIL_FROM, not mailing: $1"; return 0; }
	printf 'From: %s\r\nTo: %s\r\nSubject: [orgsync] %s\r\nDate: %s\r\n\r\n%s\r\n' \
		"${MAIL_FROM}" "${ALERT_TO}" "$1" "$(date -R)" "$2" \
		| curl -s -m 30 --url "${MAIL_RELAY}" --mail-from "${MAIL_FROM}" --mail-rcpt "${ALERT_TO}" -T - \
		|| log "could not mail the alert: $1"
}

# A step that fails mails once, and mails again once it recovers.
declare -A FAILING=()
report() { # STEP OK|FAIL DETAIL
	if [ "$2" = FAIL ]; then
		log "$1 failed: $3"
		[ -n "${FAILING[$1]:-}" ] || alert "$1 is failing" "$3"
		FAILING[$1]=1
	elif [ -n "${FAILING[$1]:-}" ]; then
		log "$1 recovered"
		alert "$1 recovered" "$1 works again."
		unset 'FAILING[$1]'
	fi
}

# --- bw serve -----------------------------------------------------------------

api() { # METHOD PATH [JSON]
	if [ $# -ge 3 ]; then
		curl -s -m 60 -X "$1" "http://127.0.0.1:${PORT}$2" -H 'Content-Type: application/json' --data-binary "$3"
	else
		curl -s -m 60 -X "$1" "http://127.0.0.1:${PORT}$2"
	fi
}

serve_start() {
	local status session
	status=$("${BW}" status 2>/dev/null | jq -r '.status' 2>/dev/null)
	if [ "${status}" = unauthenticated ] || [ -z "${status}" ]; then
		"${BW}" config server "${SERVER}" >/dev/null || return 1
		BW_CLIENTID="${ROBOT_CLIENT_ID}" BW_CLIENTSECRET="${ROBOT_CLIENT_SECRET}" \
			"${BW}" login --apikey >/dev/null || return 1
	fi
	session=$(BW_PASSWORD="${ROBOT_PASSWORD}" "${BW}" unlock --passwordenv BW_PASSWORD --raw) || return 1
	[ -n "${session}" ] || return 1
	BW_SESSION="${session}" "${BW}" serve --hostname 127.0.0.1 --port "${PORT}" >/dev/null 2>&1 &
	SERVE_PID=$!
	local _
	for _ in $(seq 1 60); do
		[ "$(api GET /status | jq -r '.data.template.status' 2>/dev/null)" = unlocked ] && return 0
		kill -0 "${SERVE_PID}" 2>/dev/null || return 1
		sleep 1
	done
	return 1
}

serve_alive() {
	kill -0 "${SERVE_PID}" 2>/dev/null \
		&& [ "$(api GET /status | jq -r '.data.template.status' 2>/dev/null)" = unlocked ]
}

# --- Steps --------------------------------------------------------------------

confirm_and_share() {
	local out members id n=0 col cid body
	out=$(api POST /sync) || { report confirm FAIL "bw serve did not answer /sync"; return 1; }
	[ "$(jq -r '.success' <<< "${out}")" = true ] || { report confirm FAIL "sync: $(jq -r '.message' <<< "${out}")"; return 1; }

	out=$(api GET "/list/object/org-members?organizationid=${ORG_ID}")
	[ "$(jq -r '.success' <<< "${out}")" = true ] || { report confirm FAIL "list members: $(jq -r '.message' <<< "${out}")"; return 1; }
	members=$(jq -c '.data.data' <<< "${out}")

	for id in $(members_to_confirm <<< "${members}"); do
		out=$(api POST "/confirm/org-member/${id}?organizationid=${ORG_ID}")
		if [ "$(jq -r '.success' <<< "${out}")" = true ]; then
			n=$((n + 1))
			log "confirmed $(jq -r --arg i "${id}" '.[] | select(.id == $i) | .email' <<< "${members}")"
		else
			report confirm FAIL "confirm ${id}: $(jq -r '.message' <<< "${out}")"; return 1
		fi
	done
	if [ "${n}" -gt 0 ]; then
		out=$(api GET "/list/object/org-members?organizationid=${ORG_ID}")
		members=$(jq -c '.data.data' <<< "${out}")
	fi

	if [ -n "${COLLECTION}" ]; then
		out=$(api GET "/list/object/org-collections?organizationid=${ORG_ID}")
		cid=$(collection_id "${COLLECTION}" <<< "${out}")
		[ -n "${cid}" ] || { report confirm FAIL "no collection with id or name '${COLLECTION}'"; return 1; }
		col=$(api GET "/object/org-collection/${cid}?organizationid=${ORG_ID}" | jq -c '.data')
		body=$(jq -n --argjson m "${members}" --argjson c "${col}" '{members: $m, collection: $c}' | collection_update "${COLLECTION_READONLY}")
		if [ -n "${body}" ]; then
			out=$(api PUT "/object/org-collection/${cid}?organizationid=${ORG_ID}" "${body}")
			[ "$(jq -r '.success' <<< "${out}")" = true ] || { report confirm FAIL "update collection: $(jq -r '.message' <<< "${out}")"; return 1; }
			log "gave '${COLLECTION}' to $(( $(jq '.users | length' <<< "${body}") - $(jq '.users | length' <<< "${col}") )) member(s)"
		fi
	fi
	report confirm OK ""
}

directory_setup() {
	local data="${BITWARDENCLI_CONNECTOR_APPDATA_DIR}/data.json" tmp
	"${BWDC}" config server "${SERVER}" >/dev/null || return 1
	"${BWDC}" config directory 2 >/dev/null || return 1
	tmp=$(bwdc_settings "${GOOGLE_KEY}" < "${data}") || return 1
	printf '%s\n' "${tmp}" > "${data}"
	chmod 600 "${data}"
	BW_CLIENTID="${ORG_CLIENT_ID}" BW_CLIENTSECRET="${ORG_CLIENT_SECRET}" "${BWDC}" login >/dev/null 2>&1 \
		|| "${BWDC}" config server "${SERVER}" >/dev/null 2>&1   # already logged in also exits non-zero
}

directory_sync() {
	local out
	if out=$(BW_CLIENTID="${ORG_CLIENT_ID}" BW_CLIENTSECRET="${ORG_CLIENT_SECRET}" "${BWDC}" sync 2>&1); then
		log "directory: $(printf '%s' "${out}" | tail -1)"
		report directory OK ""
	else
		report directory FAIL "$(printf '%s' "${out}" | tail -5)"
	fi
}

# --- Main ---------------------------------------------------------------------

[ -z "${ORGSYNC_SOURCE_ONLY:-}" ] || return 0 2>/dev/null || exit 0

main() {
	mkdir -p "${BITWARDENCLI_APPDATA_DIR}" "${BITWARDENCLI_CONNECTOR_APPDATA_DIR}"
	chmod 700 "${DATA}" "${BITWARDENCLI_APPDATA_DIR}" "${BITWARDENCLI_CONNECTOR_APPDATA_DIR}" 2>/dev/null || true
	case "${SERVER}" in
		https://*) ;;
		*) log "ORGSYNC_SERVER must be the vault's https:// address (bw refuses http), got '${SERVER}'"; exit 1 ;;
	esac
	read_secrets "${SECRETS}" || exit 1
	ORG_ID=$(org_id_from_client_id "${ORG_CLIENT_ID}") || { log "ORG_CLIENT_ID is not organization.<id>"; exit 1; }
	log "organisation ${ORG_ID}, server ${SERVER}, collection '${COLLECTION:-none}', directory ${DIRECTORY}"

	if [ "${DIRECTORY}" = gsuite ]; then
		[ -r "${GOOGLE_KEY}" ] && [ -n "${GSUITE_DOMAIN}" ] && [ -n "${GSUITE_ADMIN}" ] \
			|| { log "gsuite needs ORGSYNC_GOOGLE_KEY, ORGSYNC_GSUITE_DOMAIN and ORGSYNC_GSUITE_ADMIN"; exit 1; }
		directory_setup || { report directory FAIL "bwdc setup failed"; }
	fi

	trap 'log "stopping"; kill "${SERVE_PID}" 2>/dev/null; exit 0' TERM INT
	local next_dir=0 now
	while true; do
		if ! serve_alive; then
			kill "${SERVE_PID}" 2>/dev/null
			if serve_start; then
				log "bw serve unlocked"; report vault OK ""
			else
				report vault FAIL "could not log in and unlock the robot account"
				sleep "${CONFIRM_INTERVAL}" & wait $!; continue
			fi
		fi
		now=$(date +%s)
		if [ "${DIRECTORY}" = gsuite ] && [ "${now}" -ge "${next_dir}" ]; then
			directory_sync
			next_dir=$(( now + DIRECTORY_INTERVAL ))
		fi
		confirm_and_share
		touch "${DATA}/.heartbeat"
		sleep "${CONFIRM_INTERVAL}" & wait $!
	done
}

main "$@"
