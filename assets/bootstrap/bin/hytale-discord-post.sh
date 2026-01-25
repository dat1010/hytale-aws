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

