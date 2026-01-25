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

  if {
    echo "Hytale authentication link detected (you may need to do this twice on first deploy)."
    echo
    echo "$url"
    echo
    echo "If a device code is shown, check the instance logs for the code."
    echo
    echo "Recent auth-related server output (for codes/instructions):"
    journalctl -u hytale -n 120 --no-pager 2>/dev/null | grep -Ei 'https?://|code|device|verify|authorize|auth|session' | tail -n 30 || true
  } | /opt/hytale/bin/hytale-discord-post.sh; then
    echo "$url" >> "$SENT"
  else
    echo "WARNING: failed to post auth URL to Discord; will retry later: $url" >&2
  fi
done <<< "$urls"

