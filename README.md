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
- **`DiscordWebhookSecretArn`**: where to store the Discord webhook URL
- **`BackupsBucketName`**: S3 bucket where backups are stored

## Configure the Makefile

The `Makefile` defaults are near the top:
- **`AWS_REGION`** (default `us-east-1`)
- **`INSTANCE_ID`** (set this to the stack output `InstanceId`)
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
- **`make units`**: show unit file + status for both hytale services
- **`make diag`**: full bootstrap diagnostics (cloud-init + systemd + journald)

## Discord webhook secret (Secrets Manager)

After the stack is deployed, store the Discord webhook URL in the secret created by the stack.

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

## Superadmin / OP (grant yourself admin permissions)

This server stores permissions in:
- `/opt/hytale/server/Server/permissions.json`

The `users` map is keyed by **account UUID** (not username). To grant yourself full admin, add your UUID to the `OP` group (which is `"*"` in `groups.OP`).

### Find your UUID

Join the server once, then on the instance:

```bash
sudo grep -RIn "Auto-selected profile:" /opt/hytale/server/Server/logs | tail -n 20
```

You should see something like:
`Auto-selected profile: <username> (<uuid>)`

### Add UUID to the OP group

Replace `PUT-UUID-HERE` and run:

```bash
sudo cp /opt/hytale/server/Server/permissions.json "/opt/hytale/server/Server/permissions.json.bak.$(date +%s)"

sudo python3 - <<'PY'
import json, pathlib
p = pathlib.Path("/opt/hytale/server/Server/permissions.json")
data = json.loads(p.read_text())
uid = "PUT-UUID-HERE"

user = data.setdefault("users", {}).setdefault(uid, {})
groups = set(user.get("groups", []))
groups.add("OP")
user["groups"] = sorted(groups)

p.write_text(json.dumps(data, indent=2) + "\n")
PY

sudo python3 -m json.tool /opt/hytale/server/Server/permissions.json >/dev/null && echo "permissions.json OK"
sudo systemctl restart hytale
```

### Verify in-game

Join the server and run a non-destructive admin command like:
- `/gamemode creative`

If it succeeds (and you don’t see a permission error), you’re OP.
