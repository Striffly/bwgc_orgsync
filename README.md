# bwgc_orgsync

Keeps a [Vaultwarden](https://github.com/dani-garcia/vaultwarden) organisation
in step with a Google Workspace directory, with no manual step. Built for
[bitwarden_gcloud](https://github.com/Striffly/bitwarden_gcloud), where it runs
as the opt-in `orgsync` service.

| Every | What | How |
|---|---|---|
| 15 min | New Workspace users are invited to the organisation. With `ORGSYNC_OVERWRITE_EXISTING=true`, members no longer in Workspace are removed; suspended users are removed with `ORGSYNC_REMOVE_DISABLED=true`. | [Bitwarden Directory Connector](https://bitwarden.com/help/directory-sync/) (`bwdc`), users only, no groups |
| 1 min | Members who accepted their invitation are confirmed, and every confirmed member is given `ORGSYNC_COLLECTION`. | [Bitwarden CLI](https://bitwarden.com/help/cli/) (`bw serve`), logged in as an admin account |

Image: `ghcr.io/striffly/bwgc_orgsync:master`, Debian with the newest `bw` and
`bwdc` releases at build time (recorded in `/opt/versions`). Tested, scanned by
Trivy and signed with cosign by the shared
[bwgc_workflows](https://github.com/Striffly/bwgc_workflows), rebuilt weekly
to pick up new `bw` and `bwdc` releases, and nightly when the base image or a
package falls behind. A release that breaks the tests is never published, and
bitwarden_gcloud's autoupdate holds every new image three days before
installing it.

## Why an admin account on the server

Confirming a member means encrypting the organisation key with that member's
public key. Vaultwarden never holds the organisation key, by design, so it
cannot confirm anyone itself ([vaultwarden#754](https://github.com/dani-garcia/vaultwarden/issues/754)).
Only an unlocked client of an owner or admin can. This service is that client:
a dedicated admin account (the "robot") whose API key and master password are
stored on the server.

**The trade-off.** Without it, someone who takes the server finds only
encrypted data. With it, they can unlock the robot and read everything the
organisation shares. Members' personal vaults stay out of reach either way.
Give the robot no personal items, and keep the secrets file readable by its
owner only.

Only members with the plain **User** role are confirmed. An owner, admin or
manager always needs a human.

## Cost on an e2-micro

Measured on a GCE e2-micro: starting `bwdc` costs about 12 s of CPU and 210 MB,
even for `--version`, and `bw` about 2 s and 160 MB. So `bw serve` is started
once and stays unlocked, and the one-minute pass is a few `curl` calls to it.
`bwdc` runs every 15 minutes. The service is meant to run with a memory limit
(384 MB in bitwarden_gcloud).

## Configuration

Environment:

| Variable | Default | |
|---|---|---|
| `ORGSYNC_SERVER` | `http://bitwarden:80` | Vaultwarden, reached on the stack's network |
| `ORGSYNC_COLLECTION` | *(none)* | Collection every confirmed member is given; empty to only confirm |
| `ORGSYNC_COLLECTION_READONLY` | `true` | `false` lets members edit its items |
| `ORGSYNC_CONFIRM_INTERVAL` | `60` | Seconds between confirm passes |
| `ORGSYNC_DIRECTORY` | `gsuite` | `none` to confirm without a directory |
| `ORGSYNC_DIRECTORY_INTERVAL` | `900` | Seconds between directory syncs |
| `ORGSYNC_GSUITE_DOMAIN` | | e.g. `example.org` |
| `ORGSYNC_GSUITE_ADMIN` | | A Workspace admin the service account acts as, read-only |
| `ORGSYNC_USER_FILTER` | | bwdc filter, e.g. `exclude:noreply@example.org,contact@example.org` |
| `ORGSYNC_REMOVE_DISABLED` | `true` | Remove members suspended in Workspace |
| `ORGSYNC_OVERWRITE_EXISTING` | `false` | Remove members not in Workspace at all |
| `ORGSYNC_ALERT_TO`, `ORGSYNC_MAIL_FROM` | | Mail when a step starts failing and when it recovers |
| `ORGSYNC_MAIL_RELAY` | `smtp://msmtpd:2500` | SMTP relay without login |

With `ORGSYNC_OVERWRITE_EXISTING=true` every member must exist in Workspace,
the robot included, or the next sync removes them.

Files, mounted read-only:

- `/secrets/orgsync.env`, one `KEY=VALUE` per line, read literally: no quotes,
  no escaping, the value is everything after the first `=`.
  ```
  ROBOT_CLIENT_ID=user.…
  ROBOT_CLIENT_SECRET=…
  ROBOT_PASSWORD=…
  ORG_CLIENT_ID=organization.…
  ORG_CLIENT_SECRET=…
  ```
  The robot's key is under its account's Settings, Security, Keys. The
  organisation's is under the organisation's Settings, Organization info,
  API key.
- `/secrets/google-key.json`, the JSON key of a service account with
  domain-wide delegation for all three of
  `https://www.googleapis.com/auth/admin.directory.user.readonly`,
  `https://www.googleapis.com/auth/admin.directory.group.readonly` and
  `https://www.googleapis.com/auth/admin.directory.group.member.readonly`.
  bwdc requests the three together, even when it syncs users only, and
  Google refuses the whole token (`unauthorized_client`) if one is missing.

State (bw and bwdc data, the heartbeat) goes to `/data`.

## Tests

```
./tests/run-tests.sh
```

Builds the image and runs every case inside it, as its own user, offline: the
selection and collection logic against fixtures, the secrets parser against
hostile input, and the real `bwdc` to check the directory settings survive it
rewriting its state.
