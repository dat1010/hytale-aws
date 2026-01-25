#!/usr/bin/env bash
set -euxo pipefail

# Log for debugging (separate from cloud-init).
exec > >(tee /var/log/hytale-bootstrap.log | logger -t hytale-bootstrap -s 2>/dev/console) 2>&1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
dnf install -y --allowerasing curl-minimal unzip tar rsync awscli python3 file

source "$SCRIPT_DIR/lib/disk.sh"

# Mount data volume at /opt/hytale (persistent state volume).
MOUNTPOINT=/opt/hytale
DEVICE="$(select_hytale_data_device || true)"
if [ -z "$DEVICE" ]; then
  echo "ERROR: Could not determine the data volume device. Set HYTALE_DATA_DEVICE=/dev/<...> to override."
  exit 1
fi
ensure_ext4_mounted "$DEVICE" "$MOUNTPOINT"

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

# Install runtime scripts (kept in the bootstrap asset; copied into /opt/hytale/bin).
install -m 0755 "$SCRIPT_DIR/bin/hytale-discord-post.sh" /opt/hytale/bin/hytale-discord-post.sh
install -m 0755 "$SCRIPT_DIR/bin/hytale-update.sh" /opt/hytale/bin/hytale-update.sh
install -m 0755 "$SCRIPT_DIR/bin/hytale-server-run.sh" /opt/hytale/bin/hytale-server-run.sh
install -m 0755 "$SCRIPT_DIR/bin/hytale-auth-scan.sh" /opt/hytale/bin/hytale-auth-scan.sh
install -m 0755 "$SCRIPT_DIR/bin/hytale-backup-sync.sh" /opt/hytale/bin/hytale-backup-sync.sh
install -m 0755 "$SCRIPT_DIR/bin/hytale-restore.sh" /opt/hytale/bin/hytale-restore.sh

# Downloader install
aws s3 cp "s3://${DOWNLOADER_ASSET_BUCKET}/${DOWNLOADER_ASSET_KEY}" /opt/hytale/tmp/hytale-downloader.zip
unzip -o /opt/hytale/tmp/hytale-downloader.zip -d /opt/hytale/downloader
test -f /opt/hytale/downloader/hytale-downloader-linux-amd64
cp -f /opt/hytale/downloader/hytale-downloader-linux-amd64 /opt/hytale/downloader/hytale-downloader
chmod +x /opt/hytale/downloader/hytale-downloader
chown -R hytale:hytale /opt/hytale/downloader

# systemd units
install -m 0644 "$SCRIPT_DIR/systemd/hytale-update.service" /etc/systemd/system/hytale-update.service
install -m 0644 "$SCRIPT_DIR/systemd/hytale-update.timer" /etc/systemd/system/hytale-update.timer
install -m 0644 "$SCRIPT_DIR/systemd/hytale.service" /etc/systemd/system/hytale.service
install -m 0644 "$SCRIPT_DIR/systemd/hytale-auth-scan.service" /etc/systemd/system/hytale-auth-scan.service
install -m 0644 "$SCRIPT_DIR/systemd/hytale-auth-scan.timer" /etc/systemd/system/hytale-auth-scan.timer
install -m 0644 "$SCRIPT_DIR/systemd/hytale-backup-sync.service" /etc/systemd/system/hytale-backup-sync.service
install -m 0644 "$SCRIPT_DIR/systemd/hytale-backup-sync.timer" /etc/systemd/system/hytale-backup-sync.timer

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

