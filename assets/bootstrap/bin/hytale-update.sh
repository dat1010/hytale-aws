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

