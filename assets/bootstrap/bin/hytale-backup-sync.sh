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

