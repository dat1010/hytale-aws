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
DEVICE=/dev/xvdb
MOUNTPOINT=/opt/hytale

# SAFETY: Never auto-format a non-empty device.
# - If the device already contains any filesystem/partition signature, refuse to format
#   unless explicitly forced via FORCE_FORMAT/BOOTSTRAP_CONFIRM.
# - Only format automatically when the device is confirmed empty.
FORCE_FORMAT="${FORCE_FORMAT:-}"
BOOTSTRAP_CONFIRM="${BOOTSTRAP_CONFIRM:-}"
force=no
case "${FORCE_FORMAT,,}" in 1|true|yes|y) force=yes ;; esac
case "${BOOTSTRAP_CONFIRM,,}" in 1|true|yes|y) force=yes ;; esac

if [ ! -b "$DEVICE" ]; then
  echo "ERROR: Expected block device $DEVICE not found."
  exit 1
fi

file_out="$(file -s "$DEVICE" 2>/dev/null || true)"
is_ext4=no
if echo "$file_out" | grep -qi '\bext4\b'; then
  is_ext4=yes
fi

has_signature=no
if command -v blkid >/dev/null 2>&1; then
  if blkid -p "$DEVICE" >/dev/null 2>&1; then
    has_signature=yes
  fi
fi
if command -v lsblk >/dev/null 2>&1; then
  # If there are any partitions under the device, treat it as non-empty.
  if lsblk -nr -o TYPE "$DEVICE" 2>/dev/null | grep -q '^part$'; then
    has_signature=yes
  fi
  # If lsblk reports any filesystem type on the device or its children, treat it as non-empty.
  if lsblk -nr -o FSTYPE "$DEVICE" 2>/dev/null | grep -q '[^[:space:]]'; then
    has_signature=yes
  fi
fi
if echo "$file_out" | grep -qiE 'filesystem|partition|LVM|xfs|btrfs|swap'; then
  has_signature=yes
fi

if [ "$is_ext4" != "yes" ]; then
  if [ "$has_signature" = "yes" ] && [ "$force" != "yes" ]; then
    echo "ERROR: $DEVICE appears to contain existing data or a filesystem signature:"
    echo "  $file_out"
    echo
    echo "Refusing to format automatically to avoid data loss."
    echo "If you are sure this device can be wiped, re-run with FORCE_FORMAT=1 (or BOOTSTRAP_CONFIRM=1)."
    exit 1
  fi

  if [ "$has_signature" = "yes" ] && [ "$force" = "yes" ]; then
    echo "WARNING: FORCE_FORMAT/BOOTSTRAP_CONFIRM is set; formatting $DEVICE as ext4 (DATA LOSS)."
    mkfs -t ext4 "$DEVICE"
  elif [ "$has_signature" != "yes" ]; then
    echo "$DEVICE appears empty; formatting as ext4."
    mkfs -t ext4 "$DEVICE"
  fi
fi
mkdir -p "$MOUNTPOINT"
grep -q "^$DEVICE $MOUNTPOINT " /etc/fstab || echo "$DEVICE $MOUNTPOINT ext4 defaults,nofail 0 2" >> /etc/fstab
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
# Java options (t3a.large = 2 vCPU / 8 GiB)
# - Keep Xms/Xmx equal to avoid heap resizing pauses.
# - Leave RAM for OS + native memory + file cache.
JAVA_XMS="6G"
JAVA_XMX="6G"
# Extra JVM flags (optional override/additions)
JAVA_OPTS=""
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

if [ "$DOWNLOADER_RC" -eq 0 ]; then
  # Post-auth hardening: restrict any downloader cache/credential files.
  # We enumerate likely paths as the hytale user, then enforce ownership/perms as root.
  echo "Downloader succeeded; hardening credential/cache permissions (best-effort)."

  CREDS_LIST=/opt/hytale/tmp/hytale-downloader-credential-files.txt
  runuser -u hytale -- env HOME=/opt/hytale bash -lc '
    set -euo pipefail
    out="'"$CREDS_LIST"'"
    : > "$out"
    dirs=(
      "/opt/hytale/.cache"
      "$HOME/.cache"
      "/opt/hytale/.config"
      "$HOME/.config"
    )
    for d in "${dirs[@]}"; do
      [ -d "$d" ] || continue
      # Look for likely sensitive files produced by auth flows.
      find "$d" -maxdepth 6 -type f \( \
        -name "*token*" -o -name "*credential*" -o -name "*session*" -o -name "*oauth*" -o \
        -name "*.json" -o -name "*.dat" \
      \) -print >>"$out" 2>/dev/null || true
    done
  ' || echo "WARNING: credential file enumeration failed (continuing)."

  # Tighten dir perms (directories need +x to traverse).
  for d in /opt/hytale/.cache /opt/hytale/.config; do
    if [ -d "$d" ]; then
      chown -R hytale:hytale "$d" || true
      chmod 700 "$d" || true
    fi
  done

  if [ -s "$CREDS_LIST" ]; then
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      chown hytale:hytale "$f" || true
      chmod 600 "$f" || true
    done < "$CREDS_LIST"
  fi
  rm -f "$CREDS_LIST" || true
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

source /etc/hytale/hytale.env || true

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

JAVA_XMS="${JAVA_XMS:-6G}"
JAVA_XMX="${JAVA_XMX:-6G}"
JAVA_OPTS="${JAVA_OPTS:-}"

# Sensible defaults for server workloads on Java 25 (Corretto):
# - G1GC is the default, but we set it explicitly for clarity.
# - DisableExplicitGC avoids plugin/mod-induced full-GC spikes.
# - PerfDisableSharedMem avoids /tmp perf mmap issues in some environments.
exec /usr/bin/java \
  -Xms"$JAVA_XMS" -Xmx"$JAVA_XMX" \
  -XX:+UseG1GC \
  -XX:+ParallelRefProcEnabled \
  -XX:+DisableExplicitGC \
  -XX:+PerfDisableSharedMem \
  $JAVA_OPTS \
  -jar /opt/hytale/server/Server/HytaleServer.jar \
  --assets /opt/hytale/server/Assets.zip \
  --backup --backup-dir /opt/hytale/backups --backup-frequency 30 --backup-max-count 2 \
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

# Determine the bucket region (can differ from instance region).
# This avoids S3 "PermanentRedirect"/region mismatch failures if stacks are deployed in different regions.
bucket_region() {
  local r=""
  local out=""
  # Best-effort: try instance region first (fast, usually correct).
  if command -v curl >/dev/null 2>&1; then
    local token doc
    token="$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
    doc="$(curl -sS -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/dynamic/instance-identity/document" 2>/dev/null || true)"
    r="$(python3 -c 'import json,sys
try:
  d=json.loads(sys.stdin.read() or "{}")
  print(d.get("region",""))
except Exception:
  print("")' <<<"$doc" 2>/dev/null || true)"
  fi

  out="$(aws ${r:+--region "$r"} s3api get-bucket-location --bucket "$DEST_BUCKET" --query LocationConstraint --output text 2>/dev/null || true)"
  if [ -z "$out" ] || [ "$out" = "None" ] || [ "$out" = "null" ]; then
    echo "us-east-1"
    return 0
  fi
  # Legacy quirk: some APIs return "EU" for eu-west-1.
  if [ "$out" = "EU" ]; then
    echo "eu-west-1"
    return 0
  fi
  echo "$out"
}

BUCKET_REGION="$(bucket_region)"
export DEST_BUCKET DEST_PREFIX KEEP_LATEST BUCKET_REGION

# Upload backups (no --delete: keep historical backups in S3)
aws --region "$BUCKET_REGION" s3 sync "$SRC" "s3://$DEST_BUCKET/$DEST_PREFIX" --only-show-errors

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
region = os.environ.get("BUCKET_REGION")

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

# Restore from S3 backup (download + replace universe/)
cat > /opt/hytale/bin/hytale-restore.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOG=/opt/hytale/logs/hytale-restore.log
mkdir -p /opt/hytale/logs /opt/hytale/tmp
# Mirror output to both the log file and stdout/stderr (SSM-friendly).
exec > >(tee -a "$LOG") 2>&1

echo "==== $(date -u) Starting hytale restore ===="

source /etc/hytale/hytale.env || true

DEST_BUCKET="${BACKUP_BUCKET_NAME:-}"
DEST_PREFIX="${S3_BACKUP_PREFIX:-hytale/backups/}"

if [ -z "$DEST_BUCKET" ]; then
  echo "BACKUP_BUCKET_NAME is not set (/etc/hytale/hytale.env). Cannot restore from S3."
  exit 1
fi

# Determine the bucket region (bucket may live in a different region than the instance).
bucket_region() {
  local r=""
  local out=""
  if command -v curl >/dev/null 2>&1; then
    local token doc
    token="$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
    doc="$(curl -sS -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/dynamic/instance-identity/document" 2>/dev/null || true)"
    r="$(python3 -c 'import json,sys
try:
  d=json.loads(sys.stdin.read() or "{}")
  print(d.get("region",""))
except Exception:
  print("")' <<<"$doc" 2>/dev/null || true)"
  fi

  out="$(aws ${r:+--region "$r"} s3api get-bucket-location --bucket "$DEST_BUCKET" --query LocationConstraint --output text 2>/dev/null || true)"
  if [ -z "$out" ] || [ "$out" = "None" ] || [ "$out" = "null" ]; then
    echo "us-east-1"
    return 0
  fi
  if [ "$out" = "EU" ]; then
    echo "eu-west-1"
    return 0
  fi
  echo "$out"
}

REGION="$(bucket_region)"

want="${1:-}"

pick_latest_zip_key() {
  python3 - <<'PY'
import json, os, subprocess
bucket = os.environ["DEST_BUCKET"]
prefix = os.environ["DEST_PREFIX"]
region = os.environ["REGION"]
cmd = [
  "aws","--region",region,"s3api","list-objects-v2",
  "--bucket",bucket,"--prefix",prefix,"--output","json"
]
raw = subprocess.check_output(cmd)
data = json.loads(raw)
objs = data.get("Contents", []) or []
zips = [o for o in objs if (o.get("Key","").endswith(".zip"))]
if not zips:
  raise SystemExit(2)
latest = max(zips, key=lambda o: o.get("LastModified",""))
print(latest["Key"])
PY
}

export DEST_BUCKET DEST_PREFIX REGION

key=""
if [ -z "$want" ] || [ "$want" = "latest" ]; then
  echo "Selecting latest .zip backup in s3://$DEST_BUCKET/$DEST_PREFIX"
  key="$(pick_latest_zip_key || true)"
  if [ -z "$key" ]; then
    echo "No .zip backups found under s3://$DEST_BUCKET/$DEST_PREFIX"
    exit 1
  fi
else
  # Accept:
  # - full S3 key (contains '/')
  # - bare filename (e.g. 2026-01-15_14-30-00.zip) which is assumed under DEST_PREFIX
  if [[ "$want" == *"/"* ]]; then
    key="$want"
  else
    key="${DEST_PREFIX}${want}"
  fi
fi

base="$(basename "$key")"
tmpdir="/opt/hytale/tmp/restore"
zip="$tmpdir/$base"

echo "Restoring from s3://$DEST_BUCKET/$key"
rm -rf "$tmpdir"
mkdir -p "$tmpdir"

aws --region "$REGION" s3 cp "s3://$DEST_BUCKET/$key" "$zip" --only-show-errors
test -s "$zip"

echo "Stopping services..."
systemctl stop hytale || true
systemctl stop hytale-backup-sync.timer || true
systemctl stop hytale-backup-sync.service || true

ts="$(date -u +%s)"
backup_existing_state() {
  # Hytale backup formats vary by version/config:
  # - Some contain `universe/` (older docs)
  # - Newer versions may back up `worlds/`, `players/`, and `memories.json`
  #
  # We preserve whatever is currently present before restoring.
  did=no
  if [ -d /opt/hytale/universe ]; then
    echo "Backing up existing /opt/hytale/universe -> /opt/hytale/universe.bak.$ts"
    mv /opt/hytale/universe "/opt/hytale/universe.bak.$ts"
    did=yes
  fi

  for p in /opt/hytale/worlds /opt/hytale/players; do
    if [ -d "$p" ]; then
      echo "Backing up existing $p -> $p.bak.$ts"
      mv "$p" "$p.bak.$ts"
      did=yes
    fi
  done
  for f in /opt/hytale/memories.json; do
    if [ -f "$f" ]; then
      echo "Backing up existing $f -> $f.bak.$ts"
      mv "$f" "$f.bak.$ts"
      did=yes
    fi
  done

  if [ "$did" = "no" ]; then
    echo "No existing world state found to back up (continuing)."
  fi
}

backup_existing_state

echo "Extracting backup zip into /opt/hytale..."
unzip -o "$zip" -d /opt/hytale

# Some backup zips include paths prefixed with `opt/hytale/...` (relative), which can land at
# `/opt/hytale/opt/hytale/...` when extracted into `/opt/hytale`. If we detect that, normalize it.
if [ -d /opt/hytale/opt/hytale ] && [ ! -d /opt/hytale/universe ] && [ ! -d /opt/hytale/worlds ]; then
  echo "Detected nested /opt/hytale/opt/hytale after unzip; normalizing paths."
  shopt -s dotglob
  for item in /opt/hytale/opt/hytale/*; do
    base="$(basename "$item")"
    # Don't overwrite existing paths (we backed them up above).
    if [ -e "/opt/hytale/$base" ]; then
      echo "WARNING: /opt/hytale/$base already exists; leaving nested $item in place"
      continue
    fi
    mv "$item" "/opt/hytale/$base"
  done
  shopt -u dotglob
  rmdir /opt/hytale/opt/hytale 2>/dev/null || true
  rmdir /opt/hytale/opt 2>/dev/null || true
fi

normalize_to_universe() {
  # Normalize all known backup layouts into /opt/hytale/universe so the server always sees a
  # consistent world state location.
  mkdir -p /opt/hytale/universe

  if [ -d /opt/hytale/worlds ]; then
    if [ -e /opt/hytale/universe/worlds ]; then
      echo "WARNING: Both /opt/hytale/worlds and /opt/hytale/universe/worlds exist; leaving /opt/hytale/worlds in place"
    else
      mv /opt/hytale/worlds /opt/hytale/universe/worlds
    fi
  fi

  if [ -d /opt/hytale/players ]; then
    if [ -e /opt/hytale/universe/players ]; then
      echo "WARNING: Both /opt/hytale/players and /opt/hytale/universe/players exist; leaving /opt/hytale/players in place"
    else
      mv /opt/hytale/players /opt/hytale/universe/players
    fi
  fi

  if [ -f /opt/hytale/memories.json ]; then
    if [ -e /opt/hytale/universe/memories.json ]; then
      echo "WARNING: Both /opt/hytale/memories.json and /opt/hytale/universe/memories.json exist; leaving /opt/hytale/memories.json in place"
    else
      mv /opt/hytale/memories.json /opt/hytale/universe/memories.json
    fi
  fi
}

normalize_to_universe

has_universe_state=no
if [ -d /opt/hytale/universe/worlds ] || [ -d /opt/hytale/universe/players ] || [ -f /opt/hytale/universe/memories.json ]; then
  has_universe_state=yes
fi

if [ "$has_universe_state" != "yes" ]; then
  echo "Restore completed but expected world state was not created."
  echo "Expected something under:"
  echo "  - /opt/hytale/universe (worlds/, players/, memories.json)"
  echo
  echo "Inspect the zip contents with:"
  echo "  unzip -l \"$zip\" | head -n 80"
  exit 1
fi

# Fix ownership for restored data (best-effort).
if [ -d /opt/hytale/universe ]; then
  chown -R hytale:hytale /opt/hytale/universe
fi
if [ -d /opt/hytale/worlds ]; then
  chown -R hytale:hytale /opt/hytale/worlds
fi
if [ -d /opt/hytale/players ]; then
  chown -R hytale:hytale /opt/hytale/players
fi
if [ -f /opt/hytale/memories.json ]; then
  chown hytale:hytale /opt/hytale/memories.json
fi

echo "Starting server..."
systemctl start hytale || true
systemctl start hytale-backup-sync.timer || true

echo "==== $(date -u) Restore complete ===="
echo "Restored key: s3://$DEST_BUCKET/$key"
EOF
chmod +x /opt/hytale/bin/hytale-restore.sh

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

