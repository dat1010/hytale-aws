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

# Post using curl with retries.
# - Network errors are treated as failures (rc != 0 or empty http_code)
# - Retry transient HTTP failures (429, 5xx)
attempts="${DISCORD_POST_ATTEMPTS:-5}"
delay="${DISCORD_POST_RETRY_DELAY_SEC:-1}"
connect_timeout="${DISCORD_POST_CONNECT_TIMEOUT_SEC:-5}"
max_time="${DISCORD_POST_MAX_TIME_SEC:-15}"

CODE=""
rc=0
for ((i=1; i<=attempts; i++)); do
  tmp_err="$(mktemp)"
  set +e
  CODE="$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
    --connect-timeout "$connect_timeout" \
    --max-time "$max_time" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$WEBHOOK" 2>"$tmp_err")"
  rc=$?
  set -e
  curl_err="$(cat "$tmp_err" 2>/dev/null || true)"
  rm -f "$tmp_err"

  if [ "$rc" -ne 0 ] || [ -z "${CODE:-}" ]; then
    echo "Discord POST network error (attempt=$i/$attempts curl_exit=$rc)"
    if [ -n "${curl_err//[$' \t\r\n']/}" ]; then
      echo "$curl_err"
    fi
  elif [ "$CODE" = "204" ] || [ "$CODE" = "200" ]; then
    echo "Posted message to Discord (http=$CODE)"
    exit 0
  else
    echo "Discord POST failed (attempt=$i/$attempts http=$CODE)"
    # Retry only on rate limiting and transient server errors.
    if [ "$CODE" != "429" ] && [[ "$CODE" != 5* ]]; then
      exit 1
    fi
  fi

  if [ "$i" -lt "$attempts" ]; then
    sleep "$delay"
    delay="$((delay * 2))"
  fi
done

echo "Discord POST failed after retries (last_http=${CODE:-} last_curl_exit=${rc:-})"
exit 1

