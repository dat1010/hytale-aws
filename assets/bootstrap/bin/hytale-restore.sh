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

