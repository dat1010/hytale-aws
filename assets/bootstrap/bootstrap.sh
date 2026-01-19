#!/usr/bin/env bash
set -euxo pipefail

# Log for debugging (separate from cloud-init).
exec > >(tee /var/log/hytale-bootstrap.log | logger -t hytale-bootstrap -s 2>/dev/console) 2>&1

DOWNLOADER_ASSET_BUCKET="${DOWNLOADER_ASSET_BUCKET:-}"
DOWNLOADER_ASSET_KEY="${DOWNLOADER_ASSET_KEY:-}"
BACKUP_BUCKET_NAME="${BACKUP_BUCKET_NAME:-}"
DISCORD_WEBHOOK_SECRET_ARN="${DISCORD_WEBHOOK_SECRET_ARN:-}"

if [[ -z "$DOWNLOADER_ASSET_BUCKET" || -z "$DOWNLOADER_ASSET_KEY" ]]; then
  echo "Missing DOWNLOADER_ASSET_BUCKET/DOWNLOADER_ASSET_KEY"
  exit 1
fi

echo "==== $(date -u) Starting hytale bootstrap ===="

# tools
dnf install -y --allowerasing curl-minimal unzip tar rsync awscli python3

# Mount /dev/xvdb at /opt/hytale (persistent state volume)
if ! file -s /dev/xvdb | grep -q ext4; then
  mkfs -t ext4 /dev/xvdb
fi
mkdir -p /opt/hytale
grep -q '^/dev/xvdb /opt/hytale ' /etc/fstab || echo '/dev/xvdb /opt/hytale ext4 defaults,nofail 0 2' >> /etc/fstab
mount -a

# Java 25
rpm --import https://yum.corretto.aws/corretto.key
curl -fsSL https://yum.corretto.aws/corretto.repo -o /etc/yum.repos.d/corretto.repo
dnf clean all
dnf install -y java-25-amazon-corretto-headless

# User + dirs
useradd -r -m -d /opt/hytale -s /sbin/nologin hytale || true
mkdir -p /opt/hytale/downloader /opt/hytale/server /opt/hytale/game /opt/hytale/logs /opt/hytale/tmp /opt/hytale/bin /opt/hytale/backups
chown -R hytale:hytale /opt/hytale

# Config files (optional)
mkdir -p /etc/hytale
cat > /etc/hytale/discord.env <<EOF
DISCORD_WEBHOOK_SECRET_ARN="${DISCORD_WEBHOOK_SECRET_ARN}"
EOF
chmod 600 /etc/hytale/discord.env

cat > /etc/hytale/hytale.env <<EOF
BACKUP_BUCKET_NAME="${BACKUP_BUCKET_NAME}"
S3_BACKUP_PREFIX="hytale/backups/"
KEEP_LATEST_BACKUPS="5"
EOF
chmod 600 /etc/hytale/hytale.env

# Discord post helper (no-op if unset)
cat > /opt/hytale/bin/hytale-discord-post.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOG=/opt/hytale/logs/hytale-discord-post.log
mkdir -p /opt/hytale/logs
exec >>"$LOG" 2>&1

echo "==== $(date -u) hytale-discord-post ===="

source /etc/hytale/discord.env || true
if [ -z "${DISCORD_WEBHOOK_SECRET_ARN:-}" ]; then
  echo "DISCORD_WEBHOOK_SECRET_ARN is empty; skipping"
  exit 0
fi

# Determine region without IMDS:
# - Prefer AWS_REGION if set
# - Otherwise parse it from the Secrets Manager ARN (arn:aws:secretsmanager:<region>:...)
REGION="${AWS_REGION:-}"
if [ -z "$REGION" ]; then
  REGION="$(echo "$DISCORD_WEBHOOK_SECRET_ARN" | cut -d: -f4)"
fi
if [ -z "$REGION" ]; then
  echo "Could not determine region; skipping"
  exit 0
fi

WEBHOOK="$(aws --region "$REGION" secretsmanager get-secret-value \
  --secret-id "$DISCORD_WEBHOOK_SECRET_ARN" \
  --query SecretString \
  --output text)"
WEBHOOK=$(echo -n "$WEBHOOK" | tr -d '\r')
if [ -z "$WEBHOOK" ] || [ "$WEBHOOK" = "None" ] || [ "$WEBHOOK" = "null" ]; then
  echo "Webhook secret is empty/unset; skipping"
  exit 0
fi

# Read message from stdin (so we can send multi-line content safely)
CONTENT="$(cat)"
if [ -z "${CONTENT//[$' \t\r\n']/}" ]; then
  echo "Empty content; skipping"
  exit 0
fi

PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"content": sys.stdin.read()}))' <<<"$CONTENT")"

# Post using curl (we've already proven curl works on the instance).
CODE="$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$WEBHOOK" || true)"

if [ "$CODE" != "204" ] && [ "$CODE" != "200" ]; then
  echo "Discord POST failed (http=$CODE)"
  exit 1
fi

echo "Posted message to Discord (http=$CODE)"
EOF
chmod +x /opt/hytale/bin/hytale-discord-post.sh

# Downloader install
aws s3 cp "s3://${DOWNLOADER_ASSET_BUCKET}/${DOWNLOADER_ASSET_KEY}" /opt/hytale/tmp/hytale-downloader.zip
unzip -o /opt/hytale/tmp/hytale-downloader.zip -d /opt/hytale/downloader
test -f /opt/hytale/downloader/hytale-downloader-linux-amd64
cp -f /opt/hytale/downloader/hytale-downloader-linux-amd64 /opt/hytale/downloader/hytale-downloader
chmod +x /opt/hytale/downloader/hytale-downloader
chown -R hytale:hytale /opt/hytale/downloader

# Updater (downloads game.zip -> extracts server)
cat > /opt/hytale/bin/hytale-update.sh <<'EOF'
#!/usr/bin/env bash
set -euxo pipefail

LOG=/opt/hytale/logs/hytale-update.log
exec >> "$LOG" 2>&1

echo "==== $(date -u) Starting hytale update ===="

# If the server is already installed, do nothing.
# This is the key thing that makes stop/start user-friendly.
if [ -f /opt/hytale/server/Server/HytaleServer.jar ] && [ -f /opt/hytale/server/Assets.zip ]; then
  echo "Server already installed. Skipping update to preserve persistence/auth files."
  echo "==== $(date -u) Update skipped ===="
  exit 0
fi

mkdir -p /opt/hytale/game /opt/hytale/tmp/extracted
chown -R hytale:hytale /opt/hytale

DOWNLOADER_LOG=/opt/hytale/logs/hytale-downloader.log

# Download game.zip using the downloader.
# NOTE: this may require device auth the very first time.
# We set HOME=/opt/hytale so creds persist on disk.
set +e
runuser -u hytale -- env HOME=/opt/hytale bash -lc '
  set -euo pipefail
  cd /opt/hytale/downloader
  ./hytale-downloader \
    -skip-update-check \
    -patchline release \
    -download-path /opt/hytale/game/game.zip
' 2>&1 | tee "$DOWNLOADER_LOG"
DOWNLOADER_RC=${PIPESTATUS[0]}
set -e

if [ "$DOWNLOADER_RC" -ne 0 ]; then
  # Best-effort auth URL detection: if we see a URL, assume the downloader is asking for device/server-provider auth.
  # The downloader may print multiple device codes/URLs across retries.
  # Always prefer the *latest* oauth device verify URL with a user_code.
  URL="$(
    grep -Eo 'https?://[^[:space:]]+' "$DOWNLOADER_LOG" | tr -d '\r' | \
      grep 'oauth.accounts.hytale.com/oauth2/device/verify' | grep 'user_code=' | tail -n 1 || true
  )"
  if [ -z "$URL" ]; then
    URL="$(grep -Eo 'https?://[^[:space:]]+' "$DOWNLOADER_LOG" | tr -d '\r' | tail -n 1 || true)"
  fi
  if [ -n "$URL" ]; then
    {
      echo "Hytale authentication is required."
      echo
      echo "Open this URL (you may be prompted more than once during first deploy):"
      echo "$URL"
      echo
      echo "If a device code is shown, it should be in the logs below."
      echo "---- relevant output ----"
      grep -Ei 'https?://|code|device|verify|authorize|auth' "$DOWNLOADER_LOG" | tail -n 60 || true
      echo "-------------------------"
    } | /opt/hytale/bin/hytale-discord-post.sh || true
    echo "Auth required (URL detected). Waiting for auth completion; updater will retry later."
    exit 42
  fi
  echo "Downloader failed (no auth URL detected). Exit code: $DOWNLOADER_RC"
  exit "$DOWNLOADER_RC"
fi

test -f /opt/hytale/game/game.zip

rm -rf /opt/hytale/tmp/extracted
mkdir -p /opt/hytale/tmp/extracted
unzip -o /opt/hytale/game/game.zip -d /opt/hytale/tmp/extracted

test -d /opt/hytale/tmp/extracted/Server
test -f /opt/hytale/tmp/extracted/Assets.zip

mkdir -p /opt/hytale/server/Server
rsync -a /opt/hytale/tmp/extracted/Server/ /opt/hytale/server/Server/
cp -f /opt/hytale/tmp/extracted/Assets.zip /opt/hytale/server/Assets.zip
chown -R hytale:hytale /opt/hytale/server /opt/hytale/game

echo "==== $(date -u) Update complete ===="
EOF
chmod +x /opt/hytale/bin/hytale-update.sh

# Server runner with a simple console FIFO so we can inject `/auth ...` commands
# without needing an interactive terminal.
cat > /opt/hytale/bin/hytale-server-run.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

WORKDIR=/opt/hytale
LOG=/opt/hytale/logs/hytale-server.log
FIFO=/opt/hytale/tmp/hytale-console.fifo
FLAG=/opt/hytale/tmp/hytale-server-auth.started

mkdir -p /opt/hytale/tmp /opt/hytale/logs
cd "$WORKDIR"

# Create a FIFO for stdin (console commands).
if [ ! -p "$FIFO" ]; then
  rm -f "$FIFO"
  mkfifo "$FIFO"
fi

# Open FIFO for read+write so the reader doesn't block on open.
exec 3<>"$FIFO"

maybe_kick_server_auth() {
  # Only do this once per instance boot.
  if [ -f "$FLAG" ]; then
    return 0
  fi

  # Watch the server log for the "no tokens configured" message, then inject commands.
  # We deliberately do NOT rely on journald for server output.
  ( tail -n 0 -F "$LOG" 2>/dev/null || true ) | while IFS= read -r line; do
    case "$line" in
      *"No server tokens configured."*)
        echo "Detected missing server tokens; starting server auth flow" >>"$LOG"
        # Persist tokens to disk, then start device login (case-sensitive: Encrypted).
        printf "/auth persistence Encrypted\n" >&3 || true
        printf "/auth login device\n" >&3 || true
        date -u +"%Y-%m-%dT%H:%M:%SZ" >"$FLAG" || true
        break
        ;;
    esac
  done &
}

maybe_kick_server_auth

exec /usr/bin/java -Xms2G -Xmx3G -jar /opt/hytale/server/Server/HytaleServer.jar \
  --assets /opt/hytale/server/Assets.zip \
  --backup --backup-dir /opt/hytale/backups --backup-frequency 30 \
  <&3
EOF
chmod +x /opt/hytale/bin/hytale-server-run.sh

# Auth URL scanner (posts any URLs found in recent logs)
cat > /opt/hytale/bin/hytale-auth-scan.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SENT=/opt/hytale/tmp/hytale-auth-urls.sent
mkdir -p /opt/hytale/tmp
touch "$SENT"

files=(
  /opt/hytale/logs/hytale-update.log
  /opt/hytale/logs/hytale-downloader.log
  /opt/hytale/logs/hytale-server.log
)

# Collect raw candidates first, then sanitize (journald output can contain ANSI escapes).
raw="$(
  {
    # Scan our file logs (preferred).
    for f in "${files[@]}"; do
      [ -f "$f" ] || continue
      grep -Eo 'https?://[^[:space:]]+' "$f" || true
    done

    # Also scan journald output. This catches cases where auth URLs are written to stderr/journal.
    journalctl -u hytale-update -n 400 --no-pager 2>/dev/null | grep -Eo 'https?://[^[:space:]]+' || true
    journalctl -u hytale -n 400 --no-pager 2>/dev/null | grep -Eo 'https?://[^[:space:]]+' || true
  } | tail -n 80
)"

urls="$(
  python3 -c 'import re,sys
s=sys.stdin.read()
if not s.strip(): raise SystemExit(0)
ansi=re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
out=[]
seen=set()
for line in s.splitlines():
  u=ansi.sub("", line).strip()
  u=u.rstrip(").,;:]}>\\\"\\x27 \\t\\r\\n")
  if not (u.startswith("http://") or u.startswith("https://")): 
    continue
  if u in seen: 
    continue
  seen.add(u)
  out.append(u)
#
# If multiple device-auth URLs appear, keep only the most recent `user_code` URL
# (the code changes across retries, and only the latest matters).
from urllib.parse import urlparse, parse_qs
device_idx = None
device_user_idx = None
for i, u in enumerate(out):
  try:
    p = urlparse(u)
  except Exception:
    continue
  if p.netloc == "oauth.accounts.hytale.com" and p.path == "/oauth2/device/verify":
    device_idx = i
    qs = parse_qs(p.query or "")
    if "user_code" in qs:
      device_user_idx = i
if device_user_idx is not None:
  keep = [out[device_user_idx]]
  # also keep the plain verify URL if present (some flows show both)
  if device_idx is not None and device_idx != device_user_idx:
    keep.append(out[device_idx])
  # keep everything else except other device URLs
  rest = []
  for u in out:
    try:
      p = urlparse(u)
      if p.netloc == "oauth.accounts.hytale.com" and p.path == "/oauth2/device/verify":
        continue
    except Exception:
      pass
    rest.append(u)
  out = keep + rest

print("\n".join(out))' <<<"$raw"
)"

if [ -z "$urls" ]; then
  exit 0
fi

while IFS= read -r url; do
  [ -n "$url" ] || continue
  if grep -Fxq "$url" "$SENT"; then
    continue
  fi

  {
    echo "Hytale authentication link detected (you may need to do this twice on first deploy)."
    echo
    echo "$url"
    echo
    echo "If a device code is shown, check the instance logs for the code."
    echo
    echo "Recent auth-related server output (for codes/instructions):"
    journalctl -u hytale -n 120 --no-pager 2>/dev/null | grep -Ei 'https?://|code|device|verify|authorize|auth|session' | tail -n 30 || true
  } | /opt/hytale/bin/hytale-discord-post.sh || true

  echo "$url" >> "$SENT"
done <<< "$urls"
EOF
chmod +x /opt/hytale/bin/hytale-auth-scan.sh

# Backup sync to S3 + prune to latest N backups
cat > /opt/hytale/bin/hytale-backup-sync.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source /etc/hytale/hytale.env || true

SRC="/opt/hytale/backups"
DEST_BUCKET="${BACKUP_BUCKET_NAME:-}"
DEST_PREFIX="${S3_BACKUP_PREFIX:-hytale/backups/}"
KEEP_LATEST="${KEEP_LATEST_BACKUPS:-5}"

if [ -z "$DEST_BUCKET" ]; then
  exit 0
fi
if [ ! -d "$SRC" ]; then
  exit 0
fi

# Determine region via IMDSv2 (no local aws config needed)
TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
DOC=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/dynamic/instance-identity/document")
REGION=$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["region"])' <<<"$DOC")
export DEST_BUCKET DEST_PREFIX KEEP_LATEST REGION

# Upload backups (no --delete: keep historical backups in S3)
aws --region "$REGION" s3 sync "$SRC" "s3://$DEST_BUCKET/$DEST_PREFIX" --only-show-errors

# Prune S3 to keep only the latest N backups by *backup name*.
# We group objects by the first path component after DEST_PREFIX (handles backups as files or folders).
python3 - <<'PY'
import json
import os
import subprocess
from collections import defaultdict

bucket = os.environ.get("DEST_BUCKET")
prefix = os.environ.get("DEST_PREFIX", "")
keep = int(os.environ.get("KEEP_LATEST", "5"))
region = os.environ.get("REGION")

if not bucket or keep <= 0:
    raise SystemExit(0)

cmd = [
    "aws",
    "--region",
    region,
    "s3api",
    "list-objects-v2",
    "--bucket",
    bucket,
    "--prefix",
    prefix,
    "--output",
    "json",
]
raw = subprocess.check_output(cmd)
data = json.loads(raw)
objs = data.get("Contents", []) or []
if not objs:
    raise SystemExit(0)

groups = defaultdict(list)
for o in objs:
    key = o.get("Key", "")
    if not key or not key.startswith(prefix):
        continue
    rest = key[len(prefix) :]
    if not rest:
        continue
    group = rest.split("/", 1)[0]
    if not group:
        continue
    groups[group].append(o)

ranked = []
for group, items in groups.items():
    latest = max(i.get("LastModified", "") for i in items)
    ranked.append((latest, group))
ranked.sort(reverse=True)

keep_groups = {g for _, g in ranked[:keep]}
delete_keys = []
for group, items in groups.items():
    if group in keep_groups:
        continue
    for i in items:
        k = i.get("Key")
        if k:
            delete_keys.append(k)

if not delete_keys:
    raise SystemExit(0)

for start in range(0, len(delete_keys), 1000):
    chunk = delete_keys[start : start + 1000]
    payload = {"Objects": [{"Key": k} for k in chunk], "Quiet": True}
    subprocess.check_call(
        [
            "aws",
            "--region",
            region,
            "s3api",
            "delete-objects",
            "--bucket",
            bucket,
            "--delete",
            json.dumps(payload),
        ]
    )
PY
EOF
chmod +x /opt/hytale/bin/hytale-backup-sync.sh

# systemd units
cat > /etc/systemd/system/hytale-update.service <<'EOF'
[Unit]
Description=Hytale Update (Downloader + Extract)
After=network-online.target
Wants=network-online.target

# Only run update if server is NOT installed yet
ConditionPathExists=!/opt/hytale/server/Server/HytaleServer.jar

[Service]
Type=oneshot
TimeoutStartSec=0
ExecStart=/opt/hytale/bin/hytale-update.sh

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/hytale-update.timer <<'EOF'
[Unit]
Description=Retry Hytale update until installed

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/hytale.service <<'EOF'
[Unit]
Description=Hytale Dedicated Server
After=network-online.target hytale-update.service
Wants=network-online.target hytale-update.service

[Service]
Type=simple
User=hytale
# IMPORTANT:
# On first boot, the updater may not have created /opt/hytale/server/Server yet.
# systemd applies WorkingDirectory *before* ExecStartPre, so setting it to a not-yet-existing
# directory causes `status=200/CHDIR` and prevents the server from ever reaching auth prompts.
WorkingDirectory=/opt/hytale

# Also write stdout to a file so we can scan for auth URLs.
StandardOutput=append:/opt/hytale/logs/hytale-server.log
StandardError=append:/opt/hytale/logs/hytale-server.log

# Wait until server files exist (prevents bad boots)
ExecStartPre=/usr/bin/test -f /opt/hytale/server/Server/HytaleServer.jar
ExecStartPre=/usr/bin/test -f /opt/hytale/server/Assets.zip

ExecStart=/opt/hytale/bin/hytale-server-run.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/hytale-auth-scan.service <<'EOF'
[Unit]
Description=Scan Hytale logs for auth URLs and notify Discord
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/hytale/bin/hytale-auth-scan.sh
EOF

cat > /etc/systemd/system/hytale-auth-scan.timer <<'EOF'
[Unit]
Description=Periodic scan for Hytale auth URLs

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/hytale-backup-sync.service <<'EOF'
[Unit]
Description=Sync Hytale backups to S3
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/hytale/bin/hytale-backup-sync.sh
EOF

cat > /etc/systemd/system/hytale-backup-sync.timer <<'EOF'
[Unit]
Description=Periodic Hytale backup upload to S3

[Timer]
OnBootSec=10min
OnUnitActiveSec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable hytale-update.service hytale-update.timer hytale.service hytale-auth-scan.timer hytale-backup-sync.timer

# Start updater (only runs if missing files), then server and timers
systemctl start hytale-update.service || true
systemctl start hytale.service || true
systemctl start hytale-update.timer || true
systemctl start hytale-auth-scan.timer || true
systemctl start hytale-backup-sync.timer || true

# Fix ownership after writing scripts/log dirs as root.
chown -R hytale:hytale /opt/hytale

echo "==== $(date -u) Bootstrap complete ===="

# Best-effort: send a "bootstrap complete" message from the instance itself.
# This helps on first deploy, since the EventBridge->Lambda "running" notification can be missed
# if the instance reaches running before the rule exists.
TOKEN="$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 600" 2>/dev/null || true)"
HDR=()
if [ -n "$TOKEN" ]; then HDR=(-H "X-aws-ec2-metadata-token: $TOKEN"); fi
PUBIP="$(curl -sS "${HDR[@]}" "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)"
if [ -n "$PUBIP" ] && [ "$PUBIP" != "None" ]; then
  printf "🟢 Hytale instance bootstrap complete. Connect at `%s:5520`.\n" "$PUBIP" | /opt/hytale/bin/hytale-discord-post.sh || true
fi

