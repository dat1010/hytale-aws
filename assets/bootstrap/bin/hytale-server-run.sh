#!/usr/bin/env bash
set -euo pipefail

WORKDIR=/opt/hytale
LOG=/opt/hytale/logs/hytale-server.log
FIFO=/opt/hytale/tmp/hytale-console.fifo
COOLDOWN_FILE=/opt/hytale/tmp/hytale-server-auth.last
COOLDOWN_SEC="${HYTALE_SERVER_AUTH_COOLDOWN_SEC:-300}"

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
  # Trigger server/provider auth until tokens are persisted.
  # We gate by a cooldown so we don't spam the console if the server loops.
  should_trigger() {
    # If auth tokens exist, do nothing.
    if [ -f /opt/hytale/auth.enc ]; then
      return 1
    fi

    local now last diff
    now="$(date +%s)"
    last=0
    if [ -f "$COOLDOWN_FILE" ]; then
      last="$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)"
    fi
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    diff=$((now - last))
    if [ "$diff" -lt "$COOLDOWN_SEC" ]; then
      return 1
    fi
    echo "$now" >"$COOLDOWN_FILE" 2>/dev/null || true
    return 0
  }

  # Watch the server log for the "no tokens configured" message, then inject commands.
  # We deliberately do NOT rely on journald for server output.
  ( tail -n 0 -F "$LOG" 2>/dev/null || true ) | while IFS= read -r line; do
    case "$line" in
      *"No server tokens configured."*)
        if should_trigger; then
          echo "Detected missing server tokens; starting server auth flow" >>"$LOG"
          # Persist tokens to disk, then start device login (case-sensitive: Encrypted).
          printf "/auth persistence Encrypted\n" >&3 || true
          printf "/auth login device\n" >&3 || true
        fi
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

