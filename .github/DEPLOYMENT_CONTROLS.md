# Deployment controls: SAH-Diagnostics/frappe-hrms (ERP)

Ticket VC-649 (epic VC-650, Cyber Essentials). Review date 2026-09-23. Reviewed by `iirambashiir` (ticket owner); acceptance by a repository admin is recorded in VC-649. Repository `SAH-Diagnostics/frappe-hrms`, a public fork of `frappe/hrms`. This file is the review record and the runbook. It is kept in the repository so that changes to it go through the same review as the workflows it describes.

Credential values never appear in this file. Where a pattern matters it is described in prose. Anything the review could not confirm is marked UNVERIFIED. This file is public: it does not name the affected workflow run ids, the current rotation state, or AWS resource names. Those live in VC-649 and in the infrastructure repository.

## 1 Purpose and scope

This document does three things.

1. Records the 2026-09-23 review of repository, secret and deployment permissions (section 2).
2. Describes the intended promotion flow, the secret inventory and the controls that enforce them (sections 3 to 5).
3. Gives the repository and organisation admins a one-time runbook, in the order it must be executed (section 6), plus a quarterly review checklist (section 10).

In scope: the six SAH deploy workflows (`deploy-{prod,staging,dev}.yml`, `configure-nginx-{prod,staging,dev}.yml`), the scripts under `.github/scripts/`, the on-box environment file, the AWS Secrets Manager secrets those workflows read, and the GitHub settings that gate production. Out of scope: application security inside Frappe, the `docker/` insecure defaults (PR #4, VC-646), and the infrastructure repository beyond the rotation steps that touch it.

Roles used below:

| Role | Who | Basis |
|------|-----|-------|
| Repo admin | `mohammad-dasseh`, `alitamoor-dev`, `SAH-Admin` | Collaborator list, 2026-09-23 |
| Write | `fatimafatimaprogrammer`, `Mohsin-Zeeshan`, `Zoha-Syed`, `iirambashiir`, `Faisal-ibr03` | Collaborator list, 2026-09-23 |
| Org team | `project-engineers` (closed) | Only org team visible; no repository teams |
| Ticket owner | `iirambashiir` (write, not admin) | Cannot execute the admin runbook |

## 2 Review record (2026-09-23)

The five deploy runs in finding 1 printed credential values into logs that anyone can download without authentication while the repository is public. The values are assumed harvested regardless of whether the runs are deleted. The two July 2026 production runs and the three staging runs are the retained exposures; the December 2025 production runs are past the 90-day retention and can no longer be downloaded, but their values were the same secrets and are covered by the same rotation. Run ids are recorded in VC-649, not here.

Evidence line numbers in this table refer to the base commit `0e10158a` (the tree before this PR) unless stated otherwise.

| # | Finding | Evidence | Severity | Action in this PR / action owed | Owner | Status |
|---|---------|----------|----------|--------------------------------|-------|--------|
| 1 | Lightsail SSH private key (`lightsail_private_key_b64`) printed unmasked 9 times per run in five retained runs; the two prod runs also print the Frappe `encryption_key` 9 times each. Run metadata readable unauthenticated; logs downloadable by anyone while public. | Five retained runs, two production (July 2026) and three staging (ids in VC-649). Step "Load secrets as environment variables" in all six workflows. Root cause: `IFS='=' read -r key value` drops a single trailing `=`, so the value written to `$GITHUB_ENV` differs from the one `fetch-aws-secrets.sh:62` masked, and the step-header env dump prints it. | Critical | In PR: step deleted from all six workflows (design D1). Owed: runbook 0, 0a, 0b, 3. | Admins + ops | PR done; owed items open |
| 2 | PR #6 (merged to `staging`) masks the stripped value but is not on `main`; the workflow that deploys production is still the unmasked one until `staging` is promoted. | `main` vs `staging` diff of the three deploy workflows | Critical | Owed: promote this PR to `main` promptly after merge to `staging`. | Admins | Open |
| 3 | `setup-aws-cli.sh` echoes the full `sts get-caller-identity` JSON (AWS account id and IAM user ARN) into every public deploy log. | `.github/scripts/setup-aws-cli.sh:95` | Medium | In PR: success branch prints a one-line confirmation only (D4). | PR | Done |
| 4 | Deploy-scope AWS access key pair and region written into the on-box `.env` although nothing on the box consumes them; every on-box consumer uses the `BUCKET_*` pair. | `.github/scripts/generate-env-file.sh:33-35`; consumers `docker/bucket-env.sh:14-16`, `docker/push-to-bucket.sh:8-10`, `docker/fetch-from-bucket.sh:7-9`, `scripts/sync-files-to-s3.sh:20-22` | High | In PR: the three names removed from `REQUIRED_VARS` (D4). Owed: rotate that pair (runbook 0a note). Whether it is the same pair as the GitHub `PROD_AWS_ACCESS_KEY_ID` secret is UNVERIFIED. | PR / ops | PR done; rotation owed |
| 5 | No branch protection, no rulesets, no environments. Any of eight collaborators can push to `main`; push to `main` runs `deploy-prod.yml`; a merge and a production deploy are the same action. `workflow_dispatch` accepted from any ref. | `/branches/main/protection` 404, `/rulesets` `[]`, `/environments` empty | Critical | In PR: `environment:` binding on all six credential-holding jobs (D2), inert until environments exist. Owed: runbook 1, 4. | Admins | PR done; owed open |
| 6 | All ten secrets are repository-level, readable by any workflow on any branch, including workflows added on a feature branch. | Secrets list, 2026-09-23 | High | Owed: runbook 2 (environment secrets, delete repo copies). | Admins | Open |
| 7 | `GITHUB_TOKEN` at default (write) scope in all six workflows. | No `permissions:` block at base | Medium | In PR: top-level `permissions: contents: read` on all six plus the new controls workflow (D3). | PR | Done |
| 8 | `actions/checkout` referenced by mutable tag `v4`. | `uses:` line in each of the six | Medium | In PR: pinned to the commit `v4` resolved to on 2026-09-23 (v4.4.0), no behaviour change (R3). | PR | Done |
| 9 | CODEOWNERS names upstream maintainers who are not collaborators; every line is skipped as an unknown owner, so code-owner review can never apply. | `.github/CODEOWNERS` at base | Medium | In PR: rewritten to `/.github/`, `/docker/`, `/scripts/`, `/nginx/` owned by `@mohammad-dasseh @alitamoor-dev`; `.gitattributes` forces LF (D5). Enforcement needs runbook 4. | PR / admins | PR done; enforcement owed |
| 10 | Stray `source secrets.env` at the end of the "Retrieve secrets from AWS Secrets Manager" step in the three nginx workflows. Dead, not harmful. | `configure-nginx-*.yml`, that step | Low | In PR: deleted (R5). | PR | Done |
| 11 | `.actrc` points `act` at `.secrets`, which `.gitignore` does not exclude. | `.gitignore:24-28` covers `.env*`, `*.pem`, `*.key` only | Low | In PR: `.secrets` added to the "Deployment secrets" block (D8). | PR | Done |
| 12 | `deploy-docker-app.sh` reads `HEALTHCHECK_TIMEOUT` from the environment. The deleted step exported every key of the secret into the job environment, so a `HEALTHCHECK_TIMEOUT` key in the secret used to reach the script; without an explicit export, deleting that step would silently drop it. The export keeps that path and makes the contract explicit. | `.github/scripts/deploy-docker-app.sh:48-50` | Info | In PR: `export HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-900}"` beside the two existing exports in the Deploy step (R4). | PR | Done |
| 13 | Repository is public. Logs, run metadata and every workflow file are world-readable. A public fork cannot be made private directly. | Repository metadata | High | Owed: runbook 6 now (free while public), runbook 7 decision. | Admins | Open |
| 14 | Two past production deployers (`ahmed-wael2002`, Dec 2025 x2; `Amr-Haitham`, Jul 2026 x2) are no longer collaborators. Their access removal date and whether they held copies of the secret values is UNVERIFIED. | Prod run history | Medium | Owed: runbook 9. | Admins | Open |
| 15 | `build_image.yml` pushes `ghcr.io/<repo>:<tag>` and `:stable` to public GHCR on any tag push, with `packages: write`. Any write collaborator can publish a "stable" image by pushing a tag. | `.github/workflows/build_image.yml:6-10,20-21,61-63` | Medium | Owed: runbook 4 (tag ruleset) or disable the workflow. | Admins | Open |
| 16 | Upstream `linters.yml` and `labeller.yml` use mutable tags (`checkout@v2`, `setup-node@v2`, `setup-python@v2`, `pre-commit/action@v3.0.0`, `labeler@v4`) and default token scope. `labeller.yml` is the only `pull_request_target` workflow and does not check out code. | `.github/workflows/linters.yml:13,16,35,40`; `labeller.yml:3,10` | Low | Follow-up (upstream files). | Follow-up | Open |
| 17 | `on_release.yml` / `release_notes.yml` reference `secrets.RELEASE_TOKEN`, which is not defined. Inert. | `on_release.yml:26-27`, `release_notes.yml:41` | Info | None. Do not define that secret without a review. | - | Noted |
| 18 | Actions permission settings for the repository could not be read (403 with the write token). | API, 2026-09-23 | UNVERIFIED | Owed: runbook 5 sets them explicitly. | Admins | Open |
| 19 | `docker/docker-compose.yml` falls back to a trivial database root password and admin password when the `.env` value is empty. | `docker/docker-compose.yml:12,30,32,37` | High | Out of scope: PR #4 (VC-646, targets `main`). Not duplicated here. | PR #4 | Open elsewhere |
| 20 | History scan for committed secrets across all SAH-era branches: no `.env`, `.pem` or `.key` ever committed except `docker/.env.example` on the VC-646 branch; the diff-content grep over every SAH-era change to `.github/`, `docker/` and `scripts/` found no AWS key id, PEM header, base64 PEM marker, GitHub or Slack token, or password/secret-key assignment. | `git log --all --since=2025-11-01 -p -- .github docker scripts`, 2026-09-23 | Info | None. | - | Clean |
| 21 | Where the Frappe `encryption_key` in the prod secret originates (terraform does not write it) is UNVERIFIED. | `terraform/frappe/prod/main.tf:212-249` has no such key | Info | Runbook 0b resolves whether the leaked value is live. | Ops | Open |
| 22 | On-box `/home/ubuntu/.env` copy is written by `scp` without an explicit mode; `/opt/app/.env` is `chmod 600`. `StrictHostKeyChecking=accept-new` plus `ssh-keyscan` gives trust-on-first-use host keys. | `.github/scripts/deploy-docker-app.sh:86-87`; `setup-ssh.sh:39` | Low | VC-657: `copy-file-to-instance.sh` removes the remote file before `scp`, so the upload takes the runner file's 0600 mode; the deploy step then `mv`s it into `/opt/app` (no copy left behind). Host-key pinning is still a follow-up. | PR / follow-up | `.env` part done; host keys open |

## 3 Branches, environments and promotion flow

| Branch | GitHub environment | Deploy trigger | Box | PR base rule |
|--------|--------------------|----------------|-----|--------------|
| `develop` | `development` | push, `workflow_dispatch` | dev Lightsail | Feature branches target `develop` or `staging` per team convention |
| `staging` | `staging` | push, `workflow_dispatch` | staging Lightsail | Feature PRs target `staging` (PR #5, #6 convention). This PR targets `staging`. |
| `main` | `production` | push, `workflow_dispatch` | prod Lightsail | Only `staging` to `main` promotion PRs. Default branch is `main`. |

Promotion is develop to staging to main by pull request. At the time of review `staging` is 9 commits ahead of and 3 behind `main`; `main` carries VC-307 and VC-409 production-only commits. The three deploy workflows differ between `main` and `staging` only by the PR #6 hunks.

Each deploy workflow (workflow file, "Deploy application" step) checks out the branch it is bound to on the box via `remote/sync-repo.sh`, then runs `docker compose up -d --build`. The nginx workflows run on push to their branch when `nginx/**` or the workflow file changes.

The `environment:` key on each job (all six workflows, job level) is what connects a workflow run to the environment's required reviewers, deployment branch policy and environment secrets. Until the environments exist (runbook step 1) the key changes nothing. After step 1, a production deploy requires an approval from a named reviewer and cannot be started from a ref other than `main`. Once step 2 has moved the secrets to the environment and deleted the repository copies, the production-bound job is the only job that can read the `PROD_*` values.

## 4 Secret inventory and who can read what

### 4.1 GitHub Actions secrets (repository level today)

| Name | Purpose | Readable by (today) | Target scope |
|------|---------|---------------------|--------------|
| `AWS_SECRETS_REGION` | Region for the Secrets Manager call | Any workflow on any branch | May stay repository-level (not sensitive) |
| `PROD_AWS_ACCESS_KEY_ID`, `PROD_AWS_SECRETS_ACCESS_KEY` | Static IAM user key pair that reads the prod secret | Any workflow on any branch | `production` environment |
| `PROD_AWS_DEPLOY_SECRET_ID` | Name or ARN of the prod Secrets Manager secret | Any workflow on any branch | `production` environment |
| `STAGING_AWS_ACCESS_KEY_ID`, `STAGING_AWS_SECRETS_ACCESS_KEY`, `STAGING_AWS_DEPLOY_SECRET_ID` | As above, staging | Any workflow on any branch | `staging` environment |
| `DEV_AWS_ACCESS_KEY_ID`, `DEV_AWS_SECRETS_ACCESS_KEY`, `DEV_AWS_DEPLOY_SECRET_ID` | As above, dev | Any workflow on any branch | `development` environment |

No repository variables exist. Each workflow references exactly its own environment's three secrets plus `AWS_SECRETS_REGION`; the controls test T5 asserts this set per file.

### 4.2 AWS Secrets Manager (one JSON secret per environment)

Secret names are not recorded here. The staging name is the module default in `terraform/frappe/staging/main.tf`; the production module carries the same default value, so `secret_name` must be set in the production `terraform.tfvars` or an apply would write the staging secret. Keys in the JSON, by name only (`terraform/frappe/prod/main.tf:215-248`):

| Key | Written by | Consumed by |
|-----|-----------|-------------|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `AWS_DEPLOY_SECRET_ID` | terraform (key pair from input variables; region is a literal; secret id is the secret's own ARN) | Nothing on the box after this PR; previously copied into `/opt/app/.env` |
| `lightsail_private_key_b64`, `lightsail_host`, `lightsail_user`, `lightsail_port`, `LIGHTSAIL_IP` | terraform (`lightsail_private_key_b64` is an input variable; terraform never writes the PEM to disk) | `setup-ssh.sh` on the runner; decoded to `~/.ssh/lightsail_key` |
| `DATABASE_ENDPOINT`, `DATABASE_NAME`, `DATABASE_PASSWORD`, `DATABASE_PORT`, `DATABASE_USERNAME` | terraform database module | `generate-env-file.sh` maps them to `DB_*` for the container |
| `BUCKET_NAME`, `BUCKET_ENDPOINT`, `BUCKET_ACCESS_KEY_ID`, `BUCKET_SECRET_ACCESS_KEY`, `BUCKET_REGION` | terraform storage module (dedicated IAM user) | Container backup and fetch scripts via `docker/bucket-env.sh` |
| `CERTBOT_DOMAIN`, `CERTBOT_EMAIL`, `SITE_NAME`, `SITE_URL`, `EXISTING_SITE`, `UPDATE_CODE`, `FILES_BACK_UP_HOURS` | terraform | Workflows and container |
| `encryption_key` | UNVERIFIED (not in terraform; written out-of-band) | No consumer in this repository: nothing copies it to the box or into `site_config.json`. Origin and any out-of-band consumer are UNVERIFIED; runbook step 0b settles whether the leaked value is live. |

Readers of the Secrets Manager secret: the three static IAM users whose keys sit in GitHub secrets, plus any AWS principal with `secretsmanager:GetSecretValue` on the ARN. The IAM policy attached to those users was not reviewed here and is UNVERIFIED.

### 4.3 On-box environment file

`generate-env-file.sh` writes the file on the runner; the file is created 0600 (`umask 077`); the "Transfer environment file" step removes any old `/home/ubuntu/.env` and uploads a fresh copy via `scp`, which keeps that mode (`copy-file-to-instance.sh`); the Deploy step moves it to `/opt/app/.env` with mode 600, leaving no copy in the home directory (`deploy-docker-app.sh`, VC-657) and passes it to `docker compose --env-file` (`deploy-docker-app.sh:105-106`). Contents by name after this PR: `BUCKET_*` (five), `DATABASE_*` (five), `DB_*` (five, mapped), `SITE_NAME`, `SITE_URL`, `EXISTING_SITE`, `UPDATE_CODE`, plus `SAH_CRM_BRANCH`, which the deploy workflow appends itself (not from Secrets Manager; VC-655). The compose file forwards the `DB_*`, `SITE_*`, `EXISTING_SITE`, `BUCKET_*` and `SAH_CRM_BRANCH` values into the `frappe` container as process environment (`docker/docker-compose.yml:24-51`); `DATABASE_*` and `UPDATE_CODE` stay in the file only.

Who can read those values on the box:

| Reader | How |
|--------|-----|
| `ubuntu` (the SSH user, sudo-capable) | Owns both `.env` files; can read the container environment with `docker inspect` |
| uid 1000 inside the `frappe` container | Process environment; also `sites/<site>/site_config.json`, which holds the database password and `encryption_key` |
| Frappe System Managers | Can read `site_config.json` values through the framework's server-side APIs and the system console if it is enabled |

### 4.4 Terraform state

State for `frappe/prod` and `frappe/staging` lives in the shared terraform state bucket with a DynamoDB lock table, one state key per environment, encrypted at rest (`terraform/frappe/prod/main.tf:5-11` and `terraform/frappe/staging/main.tf:5-11`; names are in the infrastructure repository, not here). The state file holds every value in the secret JSON in clear, including `lightsail_private_key_b64` and the deploy key pair. Anyone who can read that bucket can read the current secrets. After any rotation the state must be refreshed (runbook 0a) or it will keep the old key.

## 5 Control table

| Control | Enforced by | Current state (2026-09-23) | Target state | Owner |
|---------|-------------|----------------------------|--------------|-------|
| Secret values never reach a log | No `$GITHUB_ENV` step; `::add-mask::` in `fetch-aws-secrets.sh` (count 2, T7); controls test T3 | PR removes the sink; base leaks | Enforced by CI on every PR | PR + CI |
| No credentials in source | `.gitignore` (`.env*`, `*.pem`, `*.key`, `.secrets`); controls test T6 shape scan; secret scanning + push protection | `.gitignore` present; scanning not enabled | Scanning and push protection on | Admins (runbook 6) |
| Production deploy needs a named human approval | GitHub environment `production` with required reviewers, `prevent_self_review` | No environments | Two admins as reviewers, self-review prevented | Admins (runbook 1) |
| Production deploy only from `main` | Environment deployment branch policy | None | `production` allows `main` only; `staging` allows `staging`; `development` allows `develop` | Admins (runbook 1) |
| Production credentials only readable by production jobs | Environment secrets | All repository-level | `{PROD,STAGING,DEV}_*` moved; repo copies deleted | Admins (runbook 2) |
| `main` cannot be force-pushed, deleted, or merged without review | Ruleset (org-level preferred) | None | Active, empty bypass list, 1 approval, code-owner review, stale dismissal, last-push approval, thread resolution, required checks `deployment-controls` and `Semantic Commits` | Org owner / admins (runbook 4) |
| `staging` cannot be force-pushed or deleted; PRs reviewed | Ruleset | None | Active, 1 approval, required check `deployment-controls` | Admins (runbook 4) |
| Tags cannot be pushed by write users (blocks `build_image.yml` publishing) | Tag ruleset, or workflow disabled | None | Tag creation/update/deletion admin-only | Admins (runbook 4) |
| Workflow token is read-only | `permissions: contents: read` in every SAH workflow (T1); repository default read | PR adds the block; repo default UNVERIFIED | Both | PR + admins (runbook 5) |
| Only allow-listed actions run | Repository Actions policy | UNVERIFIED (403) | GitHub-owned, verified creators, `pre-commit/action@*` | Admins (runbook 5) |
| Actions are pinned to commits | Controls test T4 | `v4` tags at base | Every `uses:` in the seven SAH workflows is a 40-hex SHA with a version comment | PR + CI |
| Deployment-relevant paths need owner review | CODEOWNERS + ruleset `require_code_owner_review` | CODEOWNERS inert | Enforced once the new file is on `main` and the ruleset is active | PR + admins (runbook 4) |
| Exposed run logs unavailable | Run deletion; minimum log retention | Five runs downloadable until their retention expires (dates in VC-649) | Deleted; retention at minimum | Write user or admin (runbook 3) |
| Leaked credentials no longer valid | Key rotation (Lightsail prod + staging, deploy key pair, `encryption_key` if live) | Status tracked in VC-649 | Rotated, old keys deleted, state refreshed | Ops (runbook 0a, 0b) |
| Access is limited to current staff | Collaborator review; org 2FA | 8 collaborators; 2 past deployers gone; 2FA state UNVERIFIED | Reviewed quarterly; 2FA required after inventory | Org owner (runbook 8, 9) |
| Controls stay in place | `deployment-controls.yml` on every PR and on push to `staging`/`main`; required check | Workflow added by this PR | Required on `main` and `staging` | Admins (runbook 10) |

## 6 Admin runbook (one-time)

Order matters. Rotation comes before log deletion because deletion does not un-leak anything and the five runs are useful evidence during the compromise assessment. Rotation is done by whoever holds AWS access to the Lightsail and Secrets Manager resources (ops); GitHub steps are done by a repository admin unless marked otherwise. `{r}` is `SAH-Diagnostics/frappe-hrms`. Every step below is a shared-environment action; do not run any of it from an automated session.

### Step 0: compromise assessment (ops)

On both boxes, since 2025-12-01 (the earliest retained exposure was December 2025):

- `sudo journalctl _COMM=sshd --since 2025-12-01` and `/var/log/auth.log*` for accepted publickey logins for `ubuntu` from addresses that are not GitHub-hosted runner ranges or known staff.
- `last -F` and `lastb -F` for interactive sessions.
- CloudTrail in `eu-west-2` for the IAM users behind the deploy key pairs and the bucket users: `GetSecretValue`, `ListSecrets`, S3 `GetObject` and `ListBucket` on the storage bucket, and any `sts:GetCallerIdentity` from unexpected sources.
- `/opt/app` and `sites/` on the box for files or cron entries not produced by the deploy scripts.

Record findings in the ticket before continuing. If unauthorised access is found, treat the database and the storage bucket as compromised too and widen the rotation.

### Step 0a: Lightsail key rotation, prod and staging (ops)

Adapted from `terraform/README.md` "Key-pair rotation" for frappe (user `ubuntu`, secret key `lightsail_private_key_b64`). Do this for prod first, then staging. Never write the private key into any repository directory or transcript.

1. `aws lightsail create-key-pair --key-pair-name <instance_name>-key-YYYYMMDD --region eu-west-2 --query privateKeyBase64 --output text > /dev/shm/newkey.pem && chmod 600 /dev/shm/newkey.pem` (or `import-key-pair` with a locally generated `ssh-keygen -t ed25519` public key).
2. Using the current key, append the new public key to `/home/ubuntu/.ssh/authorized_keys` on the instance. Prove it: `ssh -i /dev/shm/newkey.pem ubuntu@<host> true` must succeed before anything is removed.
3. Encode without line breaks: `base64 -w0 /dev/shm/newkey.pem`. Merge it into the secret JSON under `lightsail_private_key_b64` without touching other keys: read the current `SecretString`, replace that one key with `jq`, then `aws secretsmanager put-secret-value --secret-id <name> --secret-string file:///dev/shm/merged.json`. Secret names come from the infrastructure repository (`terraform.tfvars` for prod, the module default for staging).
4. Run the environment's deploy workflow once (`workflow_dispatch`) to prove CI connects with the new key.
5. Remove the old public key from `authorized_keys`, `aws lightsail delete-key-pair --key-pair-name <old>`, `shred -u /dev/shm/*.pem /dev/shm/merged.json`.
6. Update every operator's `terraform.tfvars`: `key_pair_name` to the new name and `lightsail_private_key_b64` to the new encoded value. Run `terraform plan` in `terraform/frappe/<env>`; it must show no change to `aws_secretsmanager_secret_version.frappe_env_value` and no instance replacement (`ignore_changes = [user_data, key_pair_name]` covers the instance). If the plan shows a secret version change, the tfvars value does not match what step 3 wrote; fix tfvars, do not apply.
7. The terraform state bucket still holds the old key until the next `terraform apply` refreshes the state. Either apply the no-op plan after step 6 so state is rewritten, or treat state as holding the old (now deleted) key and note that in the ticket.

Deploy key pair (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` inside the secret JSON, finding 4): those values were on both boxes in `/opt/app/.env`. Rotate the IAM user access key (`aws iam create-access-key`, update tfvars `aws_access_key_id` / `aws_secret_access_key`, update the GitHub secret if it is the same pair, `aws iam delete-access-key` for the old one). Confirm first whether it is the same pair as `PROD_AWS_ACCESS_KEY_ID` (UNVERIFIED).

### Step 0b: `encryption_key` (ops, prod)

The bench is rebuilt on every deploy, so the leaked value may no longer be the live one. Decide before acting:

1. On the prod box (the container's working directory is `/home/frappe`, the bench is `/home/frappe/frappe-bench`): `sudo docker compose -f /opt/app/docker/docker-compose.yml exec frappe sh -c 'python3 -c "import json,hashlib;print(hashlib.sha256(json.load(open(\"frappe-bench/sites/<site>/site_config.json\"))[\"encryption_key\"].encode()).hexdigest())"'`.
2. Compute the same digest of the `encryption_key` value in the prod Secrets Manager secret, on a machine you trust, without echoing the value.
3. If the digests differ, the leaked value is dead. Record both digests in the ticket and stop.
4. If they match, the leaked value is live. In a maintenance window: generate a new key (`frappe.generate_hash()` length 32), re-encrypt every `__Auth` password row and every encrypted field (Frappe stores them with the site key; use `frappe.utils.password.decrypt` with the old key and `encrypt` with the new, inside `bench --site <site> console`), write the new key to `site_config.json`. Nothing in this repository copies the secret's `encryption_key` onto the box, so either remove the key from the secret or update it only if an out-of-band process is found to read it (UNVERIFIED). Take a full `bench backup --with-files` first. The re-encrypt procedure is an outline, not verified against Frappe source; rehearse it on staging.
5. Backups already in the bucket were made under the old key and remain decryptable with it. Keep the old key in an offline password manager entry labelled with the cut-over date; do not leave it in the secret.

### Step 1: environments, branch policies, reviewers (admin)

Reviewer ids: `gh api users/mohammad-dasseh --jq .id` and `gh api users/alitamoor-dev --jq .id`. Replace both `<id ...>` placeholders below with those numbers before running (the heredoc is quoted, so nothing is expanded). Repeat the block for `staging` (branch `staging`) and `development` (branch `develop`); reviewers on non-production environments are optional but the branch policy is not.

```bash
r=SAH-Diagnostics/frappe-hrms
gh api -X PUT "repos/$r/environments/production" --input - <<'JSON'
{
  "reviewers": [
    {"type": "User", "id": <id of mohammad-dasseh>},
    {"type": "User", "id": <id of alitamoor-dev>}
  ],
  "prevent_self_review": true,
  "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}
}
JSON
gh api -X POST "repos/$r/environments/production/deployment-branch-policies" \
  --input - <<'JSON'
{"name": "main", "type": "branch"}
JSON
```

Confirm with `gh api "repos/$r/environments/production"` that `protection_rules` lists both reviewers and `prevent_self_review` is true.

### Step 2: environment secrets, then delete the repository copies (admin)

Environment secrets are encrypted with the environment's public key, so use `gh secret set` rather than a raw `PUT`. Values come from the admin's password manager, never from a run log.

```bash
r=SAH-Diagnostics/frappe-hrms
for n in PROD_AWS_ACCESS_KEY_ID PROD_AWS_SECRETS_ACCESS_KEY PROD_AWS_DEPLOY_SECRET_ID; do
  gh secret set "$n" --repo "$r" --env production
done
# same for STAGING_* -> staging, DEV_* -> development
```

Prove one deploy per environment succeeds (a `workflow_dispatch` on the matching branch), then delete the repository-level copies:

```bash
for n in PROD_AWS_ACCESS_KEY_ID PROD_AWS_SECRETS_ACCESS_KEY PROD_AWS_DEPLOY_SECRET_ID \
         STAGING_AWS_ACCESS_KEY_ID STAGING_AWS_SECRETS_ACCESS_KEY STAGING_AWS_DEPLOY_SECRET_ID \
         DEV_AWS_ACCESS_KEY_ID DEV_AWS_SECRETS_ACCESS_KEY DEV_AWS_DEPLOY_SECRET_ID; do
  gh api -X DELETE "repos/$r/actions/secrets/$n"
done
```

`AWS_SECRETS_REGION` may stay repository-level. Workflow files need no change: a secret is resolved from the job's environment first.

### Step 3: delete the five runs and set retention (write access suffices for deletion; admin for retention)

Deleting the run removes its logs, its summary and the ability to re-run it. Do this only after step 0 has captured whatever evidence is needed. The five run ids are listed in VC-649.

```bash
r=SAH-Diagnostics/frappe-hrms
for id in <run ids from VC-649>; do
  gh api -X DELETE "repos/$r/actions/runs/$id"
done
```

Then Settings, Actions, General, "Artifact and log retention": set to the minimum the organisation allows (1 day). There is no repository REST endpoint for this value; do it in the UI (verify when executing).

### Step 4: rulesets (org owner preferred; repo admin otherwise)

An organisation-level ruleset cannot be edited by repository admins, so it is the stronger control. Create it at `POST /orgs/SAH-Diagnostics/rulesets` with an added `conditions.repository_name.include: ["frappe-hrms"]`; the payload is otherwise identical to the repository-level one below. If the organisation plan does not offer organisation rulesets, use the repository-level payload and record which was used. The `Semantic Commits` context is the job name at `.github/workflows/linters.yml:8`; if upstream renames it the ruleset must follow.

```bash
r=SAH-Diagnostics/frappe-hrms
gh api -X POST "repos/$r/rulesets" --input - <<'JSON'
{
  "name": "main: production branch",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}},
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 1,
      "dismiss_stale_reviews_on_push": true,
      "require_code_owner_review": true,
      "require_last_push_approval": true,
      "required_review_thread_resolution": true
    }},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": true,
      "required_status_checks": [
        {"context": "deployment-controls"},
        {"context": "Semantic Commits"}
      ]
    }}
  ]
}
JSON

gh api -X POST "repos/$r/rulesets" --input - <<'JSON'
{
  "name": "staging: integration branch",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {"ref_name": {"include": ["refs/heads/staging"], "exclude": []}},
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 1,
      "dismiss_stale_reviews_on_push": true,
      "require_code_owner_review": false,
      "require_last_push_approval": false,
      "required_review_thread_resolution": true
    }},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": false,
      "required_status_checks": [{"context": "deployment-controls"}]
    }}
  ]
}
JSON
```

CODEOWNERS sequencing: `require_code_owner_review` is evaluated against the CODEOWNERS file on the PR's base branch. The rewritten file reaches `main` only when this PR is promoted from `staging`. Enabling the `main` ruleset before that promotion is safe (the upstream file has no valid owners, so no owner review is demanded) but the control is inert until the promotion merges. Check `GET /repos/{r}/codeowners/errors` on `main` after promotion; it must return an empty `errors` array.

Tag ruleset (blocks finding 15). Repository role id 5 is the admin role (verify when executing):

```bash
gh api -X POST "repos/$r/rulesets" --input - <<'JSON'
{
  "name": "tags: admin only",
  "target": "tag",
  "enforcement": "active",
  "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}],
  "conditions": {"ref_name": {"include": ["refs/tags/**"], "exclude": []}},
  "rules": [{"type": "creation"}, {"type": "update"}, {"type": "deletion"}]
}
JSON
```

Alternative: disable `build_image.yml` (`gh api -X PUT "repos/$r/actions/workflows/build_image.yml/disable"`) until SAH decides whether it publishes images at all. Pick one and record it in section 2 finding 15.

### Step 5: Actions policy (admin)

```bash
r=SAH-Diagnostics/frappe-hrms
gh api -X PUT "repos/$r/actions/permissions" --input - <<'JSON'
{"enabled": true, "allowed_actions": "selected"}
JSON
gh api -X PUT "repos/$r/actions/permissions/selected-actions" --input - <<'JSON'
{"github_owned_allowed": true, "verified_allowed": true, "patterns_allowed": ["pre-commit/action@*"]}
JSON
gh api -X PUT "repos/$r/actions/permissions/workflow" --input - <<'JSON'
{"default_workflow_permissions": "read", "can_approve_pull_request_reviews": false}
JSON
```

Also set "Fork pull request workflows from outside collaborators" to "Require approval for all outside collaborators": `gh api -X PUT "repos/$r/actions/permissions/fork-pr-contributor-approval" --input - <<< '{"approval_policy": "all_external_contributors"}'` (verify when executing; the UI path is Settings, Actions, General). If the organisation policy is stricter than `selected`, the organisation setting wins and the first call returns an error; read `GET /orgs/SAH-Diagnostics/actions/permissions` first.

### Step 6: secret scanning and push protection (admin)

Free while the repository is public.

```bash
gh api -X PATCH "repos/SAH-Diagnostics/frappe-hrms" --input - <<'JSON'
{"security_and_analysis": {
  "secret_scanning": {"status": "enabled"},
  "secret_scanning_push_protection": {"status": "enabled"}
}}
JSON
```

Then review Security, Secret scanning alerts. Any alert that names a Lightsail key, an AWS key or an `encryption_key` refers to the runs in finding 1 and is closed by steps 0a, 0b and 3.

### Step 7: visibility decision (admin; irreversible)

A public fork cannot be switched to private directly. The sequence is: detach from the `frappe/hrms` fork network (GitHub Support or "Leave fork network" in Settings), then change visibility. Before deciding, the following must be true or budgeted:

| Prerequisite | Why | Evidence |
|--------------|-----|----------|
| Deploy key or token on both boxes for `frappe-hrms` | The Deploy step clones `${{ github.server_url }}/${{ github.repository }}.git` anonymously | `deploy-*.yml`, "Deploy application" step; `.github/scripts/remote/sync-repo.sh` |
| Deploy key or token for `sah_crm` inside the container | `init.sh` clones `https://github.com/SAH-Diagnostics/sah_crm` anonymously on every bench rebuild; `sah_crm` is also public today | `docker/init.sh:106,111` |
| Actions minutes budget | Private repositories consume the organisation's included minutes; six deploy workflows plus linters | Org billing |
| Secret Protection budget, or a CI scanner | Secret scanning and push protection are billed per active committer on private repositories | GitHub pricing |
| Accept that it cannot be undone without losing the fork relationship | Detaching is permanent | GitHub docs |
| Organisation plan supports protected environments and rulesets on private repositories (Team or above) | On a Free organisation, steps 1 and 4 stop working the moment the repository is private | `gh api orgs/SAH-Diagnostics --jq .plan.name` (verify when executing) |

If SAH stays public, the compensating controls are: steps 1 to 6 executed, minimum log retention, no `$GITHUB_ENV` sink, `permissions: contents: read`, and the controls test on every PR. Record "stay public, compensating controls accepted" or "go private on <date>" in section 2 finding 13 with the deciding admin's name.

### Step 8: organisation two-factor authentication (org owner)

Inventory first: `gh api "orgs/SAH-Diagnostics/members?filter=2fa_disabled" --jq '.[].login'`. Enforcing the requirement removes every member without 2FA from the organisation immediately, including service accounts. Contact each listed member, wait for them to enrol, then enable "Require two-factor authentication" in the organisation security settings. `SAH-Admin` must be classified first (step 9).

### Step 9: collaborator and access review (admin)

```bash
r=SAH-Diagnostics/frappe-hrms
gh api "repos/$r/collaborators?affiliation=all" --jq '.[] | [.login, .role_name] | @tsv'
gh api "repos/$r/invitations" --jq '.[] | [.invitee.login, .permissions] | @tsv'
```

- Confirm each of the eight current collaborators is current staff and needs write. Downgrade to `triage` or `read` where write is not needed for day-to-day work.
- `ahmed-wael2002` and `Amr-Haitham` ran production deploys and are no longer collaborators. Confirm the removal dates in the organisation audit log (Organisation settings, Audit log, filter `repo:SAH-Diagnostics/frappe-hrms action:repo.remove_member`; the REST endpoint for the audit log requires GitHub Enterprise Cloud), confirm neither holds an outstanding invitation, and treat every secret value they could have seen as covered by step 0a.
- Classify `SAH-Admin`: either a named human who signs in with 2FA, or a break-glass account whose password is held offline and whose use is logged. It is never a routine production approver and is never listed in the `production` reviewers.
- Record the outcome in section 2 finding 14.

### Step 10: make `deployment-controls` a required check (admin)

Already part of the rulesets in step 4. If step 4 was done before this PR's first `deployment-controls` run had reported, the context will not appear in the ruleset UI picker; the API call accepts it by name regardless. Confirm after the first PR against `staging` that the check appears as "Required" on the PR.

## 7 Named people and automation

| Actor | Role in production deployment | Notes |
|-------|-------------------------------|-------|
| `mohammad-dasseh` | Production approver; code owner for `/.github/`, `/docker/`, `/scripts/`, `/nginx/` | Repo admin |
| `alitamoor-dev` | Production approver; code owner as above | Repo admin |
| `SAH-Admin` | Classification pending (human or break-glass) | Never a routine approver |
| Write collaborators | Open PRs; cannot approve their own PR; cannot push to `main` or `staging` after step 4 | |
| `GITHUB_TOKEN` | Read-only (`contents: read`) in every SAH workflow | Cannot write to the repository or approve PRs |
| Static IAM deploy users (one per environment) | Read one Secrets Manager secret | Pending replacement by OIDC (section 8) |
| Lightsail `ubuntu` SSH identity | Target of the deploy | Key to be rotated in step 0a (owed) |

Emergency path when a required reviewer is absent: an admin temporarily edits the `production` reviewer list (adds themselves or another admin), approves, then restores the list. Every edit is recorded in the organisation audit log (`environment.update_protection_rule`). The change and its reason are noted in the next quarterly review (section 10). There is no bypass on the rulesets; the emergency path is the reviewer list only.

### 7.1 Policy statements (proposed; admins confirm or amend in VC-649)

| Statement | Status |
|-----------|--------|
| Approved secret stores are: GitHub environment secrets, AWS Secrets Manager, the terraform state bucket, and one named password manager for operator copies. Nothing else, including chat, tickets and local files. | Proposed; the password manager is to be named |
| Human access to AWS (Secrets Manager, Lightsail, the state bucket) uses MFA. | UNVERIFIED; confirm during runbook step 0a |
| Lightsail SSH keys and static IAM access keys are rotated at least every 12 months, and immediately when someone who could have read them leaves. | Proposed cadence |
| On collaborator removal: remove access within one working day, then treat every secret they could read as compromised and rotate (step 0a). | Proposed |
| The quarterly review in section 10 has a named owner and deputy and is recorded in epic VC-650. | Proposed owner `mohammad-dasseh`, deputy `alitamoor-dev` |
| Finding 1 is handled as a security incident in VC-649; closure requires steps 0, 0a, 0b and 3 and an update to this record. | Proposed |

## 8 Target state: OIDC

Recorded here so that the follow-up ticket implements exactly this and nothing else.

OIDC provider `token.actions.githubusercontent.com`, one role per environment, trust `aud = sts.amazonaws.com`, `sub = repo:SAH-Diagnostics/frappe-hrms:environment:<production|staging|development>`, `secretsmanager:GetSecretValue` on one ARN, `permissions: id-token: write`, delete six static-key secrets; OIDC does not remove the bucket key on the box (Lightsail has no instance roles).

The controls test T1 already permits `id-token: write` alongside `contents: read` so the workflows can adopt OIDC without weakening T1. The three `*_AWS_DEPLOY_SECRET_ID` secrets stay (they are names, not credentials); `AWS_SECRETS_REGION` stays.

## 9 Public repository: consequences and decision

Consequences of being public, as observed in this review:

- Run logs and run metadata are readable without authentication. This is how the five runs in finding 1 exposed the SSH key and `encryption_key` to the internet, not just to collaborators.
- Every workflow file, script and this document are world-readable. Nothing in them is secret by design; the doc names no values.
- `ghcr.io/SAH-Diagnostics/frappe-hrms` images published by `build_image.yml` are public.
- Secret scanning and push protection are free (step 6).
- The sibling `sah_crm` repository is also public and is cloned anonymously by `init.sh`; going private here without doing the same there leaves half the deployed code public.

Decision: pending, owner repo admins, prerequisites in step 7. Until decided, the repository is treated as public and the compensating controls in step 7 apply. The decision and its date go into section 2 finding 13.

## 10 Quarterly review checklist

Run as a repository admin. Paste the outputs into the ticket for that quarter's review. `r=SAH-Diagnostics/frappe-hrms`.

| Check | Command | Expected |
|-------|---------|----------|
| Environments exist with reviewers and branch policy | `gh api "repos/$r/environments" --jq '.environments[] \| {name, protection_rules, deployment_branch_policy}'` | `production`, `staging`, `development`; production has two `required_reviewers` and `custom_branch_policies: true` |
| Branch policies | `for e in production staging development; do gh api "repos/$r/environments/$e/deployment-branch-policies" --jq '.branch_policies[].name'; done` | `main`, `staging`, `develop` respectively, one each |
| Rulesets active | `gh api "repos/$r/rulesets" --jq '.[] \| [.name, .enforcement, .source_type] \| @tsv'` and `gh api "orgs/SAH-Diagnostics/rulesets" --jq '.[] \| [.name, .enforcement] \| @tsv'` | `main`, `staging`, tag rulesets all `active`; bypass lists empty except the tag ruleset |
| Repository secrets | `gh api "repos/$r/actions/secrets" --jq '.secrets[].name'` | Only `AWS_SECRETS_REGION` |
| Environment secrets | `for e in production staging development; do gh api "repos/$r/environments/$e/secrets" --jq '.secrets[].name'; done` | Exactly three per environment with the matching prefix |
| Collaborators | `gh api "repos/$r/collaborators?affiliation=all" --jq '.[] \| [.login, .role_name] \| @tsv'` | Matches the current staff list; admins are `mohammad-dasseh`, `alitamoor-dev`, plus `SAH-Admin` per its classification |
| Actions policy | `gh api "repos/$r/actions/permissions"; gh api "repos/$r/actions/permissions/selected-actions"; gh api "repos/$r/actions/permissions/workflow"` | `selected`; GitHub-owned + verified + `pre-commit/action@*`; `read`, `can_approve_pull_request_reviews: false` |
| Latest production deploys | `gh api "repos/$r/actions/workflows/deploy-prod.yml/runs?per_page=10" --jq '.workflow_runs[] \| [.id, .event, .head_branch, .actor.login, .conclusion, .created_at] \| @tsv'` | Every run on `main`, actor is a current collaborator, each has an approval in its deployment review |
| CODEOWNERS valid | `gh api "repos/$r/codeowners/errors"` | `{"errors": []}` |
| Secret scanning on | `gh api "repos/$r" --jq .security_and_analysis` | `secret_scanning` and `secret_scanning_push_protection` `enabled` |
| Open secret-scanning alerts | `gh api "repos/$r/secret-scanning/alerts?state=open" --jq length` | `0` |
| Controls workflow green on `main` and `staging` | `gh api "repos/$r/actions/workflows/deployment-controls.yml/runs?per_page=5" --jq '.workflow_runs[] \| [.head_branch, .conclusion] \| @tsv'` | All `success` |
| Emergency reviewer edits since last review | Organisation settings, Audit log, action `environment.update_protection_rule` (REST needs Enterprise Cloud) | Each one has a note in the ticket |
| Key age | `aws lightsail get-key-pairs --query 'keyPairs[].[name,createdAt]'` and `aws iam list-access-keys --user-name <deploy user>` | Rotated within the organisation's rotation period |

## 11 Follow-ups

Each is outside this PR. Raise one ticket per line unless already covered.

- OIDC for the three deploy identities per section 8 (infrastructure repository).
- Rotation, `encryption_key` check and run deletion per runbook steps 0 to 3 (shared environment; user decision).
- All repository and organisation settings per runbook steps 1 to 10 (admin).
- `docker/` insecure defaults: PR #4 (VC-646), targets `main`; expect a small `REQUIRED_VARS` conflict with this PR at promotion, resolve by keeping both changes.
- `linters.yml` and `labeller.yml`: pin actions to commits, add `permissions:` (upstream files).
- `generate-env-file.sh:60` and `fetch-aws-secrets.sh:78` still use `IFS='=' read`; no live impact today (the python branch is the one that runs) but the jq fallback would strip a trailing `=`.
- `rm -f ~/.ssh/lightsail_key` and `~/.aws/credentials` in the Cleanup step (hosted runners are ephemeral, so this is hygiene only).
- `deploy-docker-app.sh` prints `docker compose logs --tail=50` on every deploy and `remote/verify-site.sh` prints `--tail=100` on failure; container stdout reaches the public log, and the container holds `DB_PASSWORD`, `ADMIN_PASSWORD` and `BUCKET_SECRET_ACCESS_KEY` in its environment. Masking covers exact values only. Decide whether to keep those log dumps on a public repository. **Resolved by VC-657:** neither script prints container logs any more; on a failed check `verify-site.sh` writes them to `/var/log/erp-deploy/last-failure.log` on the box (dir 0700, file 0600, root).
- `source secrets.env` in every consuming step shell-interprets values; a value containing a space, `;` or `$(` would execute and print a fragment. Quote values in `fetch-aws-secrets.sh` (`shlex.quote`) and reject multi-line values there (only the first line of a multi-line value is masked).
- `sync-repo.test.sh` leaves its temporary fixture directories behind on each run (pre-existing; harmless on ephemeral runners).
- Decide whether CODEOWNERS should also cover `*` (application code that runs in production) or whether the one-approval ruleset is enough for `hrms/`.
- Host key trust: replace `ssh-keyscan` plus `accept-new` with pinned host keys in the secret.
- ~~`chmod 600` on `/home/ubuntu/.env` at copy time, or write it under `/opt/app` only.~~ Done in VC-657 (see row 22).
- Confirm the IAM policy on each static deploy user is limited to `secretsmanager:GetSecretValue` on its one ARN.
- Apply the same review to `SAH-Diagnostics/sah_crm`.

## 12 Verification notes

What this PR proves locally, on the branch before push:

- `.github/scripts/__tests__/deployment-controls.test.sh` green on the branch (T1 to T11).
- Red on base: the same test run against a `git archive 0e10158a68ef6d73d62a7b9d268d4e6bfaca88f1` extraction fails T1, T2, T3, T4, T8, T9, T10, T11 and passes T5, T6, T7, as the plan predicts.
- Mutation runs on temporary copies, each failing exactly its own assertion: re-adding a `GITHUB_ENV` line (T3); un-pinning one checkout (T4); adding `deployments: write` (T1); adding a job-level `permissions:` block (T1); adding a second job without an environment (T2); adding a bulk `toJSON(secrets)` reference (T5); planting a base64-encoded PEM header (T6); removing the `docker/` scan root (T6); plus the per-assertion set for T7 to T11.
- `.github/scripts/__tests__/sync-repo.test.sh`: 23 passed, 0 failed (unchanged from base).
- `docker run rhysd/actionlint` scoped to the seven SAH workflows: exit 0. The only finding on the branch before the last edit was the pre-existing unquoted `>> $GITHUB_STEP_SUMMARY` redirect in each summary step (shellcheck SC2086); it is quoted in this PR so the seven files lint clean.
- `bash -n` on every edited script; per-step `awk` scan confirming every step that reads a secret value sources `secrets.env` first; `grep -n GITHUB_ENV` over the six workflows returns nothing; after `git add`, `git ls-files --eol` shows an LF index entry for every edited file; `git diff --check` clean.

What is proved only by CI or by the first deploy after merge:

- D1 at runtime: the first automatic staging deploy after merge (push to `staging` runs `deploy-staging.yml`) is the proof that removing the `$GITHUB_ENV` step broke nothing. Every consuming step already sourced `secrets.env` itself; the deleted step's exports were unused.
- `permissions: contents: read` sufficiency: this PR's own `deployment-controls` run and that staging deploy.
- `environment:` gating, environment secrets, deployment branch policies and CODEOWNERS enforcement: only after runbook steps 1, 2 and 4. Until then the keys are present but inert.
- Production: only after this PR is promoted from `staging` to `main`; until then `main` still runs the workflow in finding 2.

What this PR does not and cannot prove: that the leaked values are no longer valid. That is runbook steps 0a and 0b, and it is owed.
