# Hytale Dedicated Server on AWS (CDK)

This repo deploys a small, self-contained AWS setup to run a **Hytale dedicated server** on a single EC2 instance, with a `Makefile` to start/stop and diagnose the server via SSM.

Reference docs:
- Hytale server setup guide: `https://support.hytale.com/hc/en-us/articles/45326769420827-Hytale-Server-Manual#server-setup`
- Server provider auth guide (future): `https://support.hytale.com/hc/en-us/articles/45328341414043-Server-Provider-Authentication-Guide`

## Prerequisites (WSL-friendly)

- **AWS CLI** configured (`aws configure` or env creds)
- **Node.js + npm**
- **CDK** (uses `npx cdk ...`)
- (Recommended) **Session Manager plugin** for interactive `make ssm` sessions

## Deploy

Install deps:

```bash
npm ci
```

## First deploy: Hytale authentication (2 browser auth steps)

On a **fresh** instance, Hytale typically requires authentication before it can download/run the server. In practice there are **two separate times** you may be prompted with an auth URL/device code:

- **Step 1**: the **downloader** (device auth to download `game.zip`)
- **Step 2**: the **server** (server/provider auth while the server is starting)

This repo supports **two ways** to handle those prompts:

- **Discord (recommended, optional)**: auth URLs get posted to Discord via a webhook
- **SSM (no Discord)**: you open an SSM session and read the URLs from logs

Either way, once you complete auth, the instance will keep retrying automatically (a timer reruns the updater every ~5 minutes until the install succeeds).

## Backups (Hytale → S3, survive `cdk destroy`)

Hytale supports automatic backups via `--backup` / `--backup-dir` / `--backup-frequency`. This repo uses that built-in backup output and periodically uploads it to an **S3 bucket** that lives in a separate stack.

- `HytaleServerStack` runs the server with:
  - `--backup`
  - `--backup-dir /opt/hytale/backups`
  - `--backup-frequency 30` (minutes)
- A `systemd` timer runs every ~30 minutes to `aws s3 sync` `/opt/hytale/backups` to S3 and **prunes S3 to keep only the latest 5 backups**.
- `HytaleDataStack` owns the S3 bucket and can be deployed once and kept forever.

Deploy the data stack first (do this once):

```bash
npx cdk deploy HytaleDataStack
```

Deploy (set `AllowedCidr` to your IP `/32` for safety):

```bash
npx cdk deploy --parameters AllowedCidr=YOUR.IP.ADDRESS.HERE/32
```

Destroy ONLY the server (keep backups in S3):

```bash
npx cdk destroy HytaleServerStack
```

Useful outputs from the stack:
- **`InstanceId`**: used by the `Makefile`
- **`PublicIp`**: current public IP when running (also see `make ip`)
- **`DiscordWebhookSecretArn`**: where to store the Discord webhook URL (**only if Discord is enabled**)
- **`BackupsBucketName`**: S3 bucket where backups are stored

## Restore from S3 backups (after redeploy)

This repo installs a helper on the instance: `/opt/hytale/bin/hytale-restore.sh`.

- **What it restores**: the `universe/` save data (worlds/players) by downloading a selected **backup `.zip`** from S3 and extracting it into `/opt/hytale` (so it recreates `/opt/hytale/universe`).
- **Safety**: it stops the `hytale` service first and renames any existing `/opt/hytale/universe` to `/opt/hytale/universe.bak.<timestamp>`.

If you see `command not found` for `/opt/hytale/bin/hytale-restore.sh`, your instance was bootstrapped before this helper existed. In that case, either:
- re-create the instance (destroy/redeploy the server stack), or
- install the script manually on the instance (copy/paste from `assets/bootstrap/bootstrap.sh`).

If you see `403 Forbidden` while downloading a backup from S3, the instance role is missing read access to the backups bucket. Redeploy the stack after updating IAM permissions, then retry restore.

From your workstation:

```bash
make list-backups
make restore-latest

# Or pick a specific backup zip name:
make restore BACKUP=2026-01-15_14-30-00.zip
```

## Discord integration (optional)

Discord is **enabled by default** (recommended). Disable it completely with:

```bash
npx cdk deploy -c discordEnabled=false --parameters AllowedCidr=YOUR.IP.ADDRESS.HERE/32
```

If Discord is enabled but you **don’t** configure the webhook secret, all Discord messages are simply **skipped** (you can still use the SSM/logs workflow).

## Configure the Makefile

This repo is easiest to use with [`direnv`](https://direnv.net/) so your AWS/instance settings are picked up automatically by `make`.

1) Copy the example file:

```bash
cp .envrc.example .envrc
```

2) Edit `.envrc` and set:
- **`AWS_REGION`** (defaults to `us-east-1` if unset)
- **`INSTANCE_ID`** (set this to the stack output `InstanceId`)

3) Allow `direnv`:

```bash
direnv allow
```

If you see errors like `./.envrc:7: $'\r': command not found`, your `.envrc` has Windows (CRLF) line endings. Convert it to LF (example: `dos2unix .envrc`) or configure your editor to save `.envrc` with LF.

The `Makefile` also supports:
- **`PORT`** (default `5520`)

You can override per-command:

```bash
make status AWS_REGION=us-east-1 INSTANCE_ID=i-xxxxxxxxxxxxxxxxx
```

## Make commands

- **`make up`**: start the EC2 instance
- **`make down`**: stop the EC2 instance
- **`make status`**: show EC2 state + IPs + instance type
- **`make ip`**: print `public-ip:5520` (fails if the instance is stopped)
- **`make ssm`**: open an interactive SSM session (requires Session Manager plugin)
- **`make check`**: show `systemctl` status for the Hytale service
- **`make logs`**: tail the Hytale service logs (journalctl)
- **`make update-logs`**: tail the one-time updater logs (journalctl)
- **`make port`**: check if something is listening on UDP 5520
- **`make service-restart`**: restart the Hytale service
- **`make list-backups`**: list backups stored in S3
- **`make restore-latest`**: restore the latest backup `.zip` from S3 (replaces `universe/`)
- **`make restore BACKUP=<zip>`**: restore a specific backup from S3
- **`make units`**: show unit file + status for both hytale services
- **`make diag`**: full bootstrap diagnostics (cloud-init + systemd + journald)

## Common on-instance paths

This repo keeps **persistent server state** under `/opt/hytale` (mounted on the secondary EBS volume).

- **`/opt/hytale/logs/`**: file logs written by the bootstrap scripts and server wrapper
- **`/opt/hytale/server/Server/HytaleServer.jar`**: server jar (installed by updater)
- **`/opt/hytale/server/Assets.zip`**: assets zip (installed by updater)
- **`/opt/hytale/backups/`**: built-in Hytale backups (synced to S3 by a timer)
- **`/opt/hytale/config.json`**: server config
- **`/opt/hytale/permissions.json`**: permissions / OP / groups
- **`/opt/hytale/whitelist.json`**: whitelist
- **`/opt/hytale/bans.json`**: bans
- **`/opt/hytale/auth.enc`**: persisted auth tokens (created by the server auth flow)
- **`/opt/hytale/bin/`**: helper scripts installed by bootstrap (update, run, backup sync, etc.)
- **`/etc/systemd/system/hytale*.{service,timer}`**: systemd units created by bootstrap

## Discord webhook secret (Secrets Manager)

If Discord is enabled, after the stack is deployed, store the Discord webhook URL in the secret created by the stack.

### Option A (recommended): set webhook during deploy

If you have `DISCORD_WEBHOOK_URL` in your environment (for example from `.envrc` + `direnv`), pass it as a deploy parameter:

```bash
npx cdk deploy HytaleServerStack \
  --parameters AllowedCidr=YOUR.IP.ADDRESS.HERE/32 \
  --parameters DiscordWebhookUrl="$DISCORD_WEBHOOK_URL"
```

Use `DiscordWebhookUrl=null` (default) to disable Discord posting.

#### Deploying multiple stacks?

CDK applies `--parameters` to **all stacks in that deploy command**. If you deploy multiple stacks (e.g. `--all`) you must scope the parameter to `HytaleServerStack`:

```bash
npx cdk deploy --all \
  --parameters HytaleServerStack:AllowedCidr=YOUR.IP.ADDRESS.HERE/32 \
  --parameters HytaleServerStack:DiscordWebhookUrl="$DISCORD_WEBHOOK_URL"
```

### Option B: set webhook after deploy

```bash
REGION="us-east-1"
STACK="HytaleServerStack"
DISCORD_WEBHOOK_URL="YOUR_DISCORD_WEBHOOK_URL"

SECRET_ARN="$(aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='DiscordWebhookSecretArn'].OutputValue" \
  --output text)"

aws secretsmanager put-secret-value \
  --region "$REGION" \
  --secret-id "$SECRET_ARN" \
  --secret-string "$DISCORD_WEBHOOK_URL"
```

Optional verification:

```bash
aws secretsmanager get-secret-value \
  --region "$REGION" \
  --secret-id "$SECRET_ARN" \
  --query SecretString \
  --output text
```

## Auth workflow: Discord path

- **Before starting the instance**: configure the Discord webhook secret (section above).
- **Start the instance**: `make up`
- **When auth is required**:
  - You’ll get a Discord message containing an auth URL (and usually a device code in the accompanying log excerpt).
  - Complete the auth in your browser.
  - Repeat if/when you get a second auth URL during server startup (**this is common on first deploy**).

### Important: server/provider auth is automatic

On first deploy, the server may require “server/provider” authentication (it logs messages like `No server tokens configured`). This repo automatically triggers the server console auth flow:

- sets credential persistence: `/auth persistence Encrypted` (**case-sensitive**)
- starts device login: `/auth login device`

So in the Discord workflow, you should only need to **click the links** that get posted.

If you want to watch progress, use:
- `make update-logs` (downloader/update logs)
- `make logs` (server logs)

## Auth workflow: SSM (no Discord)

- **Start the instance**: `make up`
- **Open an SSM session**: `make ssm`
- **Watch logs for auth URLs**:
  - Updater/downloader: `sudo journalctl -u hytale-update -n 300 --no-pager`
  - Server: `sudo journalctl -u hytale -n 300 --no-pager`
- **When you see an auth URL + code**: open the URL in your browser and complete it.
- **Do this twice** if you get prompted again later (downloader first, then server/provider auth).

## Superadmin / OP (grant yourself admin permissions)

This server stores permissions in:
- `/opt/hytale/permissions.json`

The `users` map is keyed by **account UUID** (not username). To grant yourself full admin, add your UUID to the `OP` group (which is `"*"` in `groups.OP`).

### Find your UUID

Join the server once, then on the instance:

```bash
sudo grep -RIn "Auto-selected profile:" /opt/hytale/logs | tail -n 20
```

You should see something like:
`Auto-selected profile: <username> (<uuid>)`

### Add UUID to the OP group

Replace `PUT-UUID-HERE` and run:

```bash
sudo cp /opt/hytale/permissions.json "/opt/hytale/permissions.json.bak.$(date +%s)"

sudo python3 - <<'PY'
import json, pathlib
p = pathlib.Path("/opt/hytale/permissions.json")
data = json.loads(p.read_text())
uid = "PUT-UUID-HERE"

user = data.setdefault("users", {}).setdefault(uid, {})
groups = set(user.get("groups", []))
groups.add("OP")
user["groups"] = sorted(groups)

p.write_text(json.dumps(data, indent=2) + "\n")
PY

sudo python3 -m json.tool /opt/hytale/permissions.json >/dev/null && echo "permissions.json OK"
sudo systemctl restart hytale
```

### Verify in-game

Join the server and run a non-destructive admin command like:
- `/gamemode creative`

If it succeeds (and you don’t see a permission error), you’re OP.
