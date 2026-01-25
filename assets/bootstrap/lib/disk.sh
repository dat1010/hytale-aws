#!/usr/bin/env bash
set -euo pipefail

# Select the data disk device path used for /opt/hytale.
#
# Defaults:
# - If HYTALE_DATA_DEVICE is set (e.g. /dev/nvme1n1), use it.
# - Else if /dev/xvdb exists, use it (historical/non-NVMe mapping).
# - Else try to discover the non-root disk by size (DATA_VOLUME_SIZE_GIB, default 30).
select_hytale_data_device() {
  local override="${HYTALE_DATA_DEVICE:-}"
  if [ -n "$override" ]; then
    echo "$override"
    return 0
  fi

  if [ -b /dev/xvdb ]; then
    echo "/dev/xvdb"
    return 0
  fi

  local want_gib="${DATA_VOLUME_SIZE_GIB:-30}"
  local want_bytes="$((want_gib * 1024 * 1024 * 1024))"

  # Find the root disk name (e.g. nvme0n1 or xvda) so we can exclude it.
  local root_disk=""
  if command -v findmnt >/dev/null 2>&1; then
    # SOURCE could be /dev/nvme0n1p1 -> we strip partition suffix later via lsblk.
    local root_src
    root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    if [[ "$root_src" == /dev/* ]]; then
      root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)"
    fi
  fi

  # List candidate whole disks that are not the root disk, not mounted, and match the expected size.
  # Output: /dev/<name>
  local best=""
  while read -r name size mount; do
    [ -n "${name:-}" ] || continue
    [ -n "${size:-}" ] || continue

    if [ -n "$root_disk" ] && [ "$name" = "$root_disk" ]; then
      continue
    fi
    # mount can be blank when unmounted.
    if [ -n "${mount:-}" ]; then
      continue
    fi

    # Exact size match is the safest discriminator.
    if [ "$size" -eq "$want_bytes" ]; then
      best="/dev/$name"
      break
    fi
  done < <(lsblk -b -dn -o NAME,SIZE,MOUNTPOINT 2>/dev/null || true)

  if [ -n "$best" ] && [ -b "$best" ]; then
    echo "$best"
    return 0
  fi

  return 1
}

# Format as ext4 only when safe, then ensure mounted.
ensure_ext4_mounted() {
  local device="$1"
  local mountpoint="$2"

  # SAFETY: Never auto-format a non-empty device.
  # - If the device already contains any filesystem/partition signature, refuse to format
  #   unless explicitly forced via FORCE_FORMAT/BOOTSTRAP_CONFIRM.
  # - Only format automatically when the device is confirmed empty.
  local FORCE_FORMAT="${FORCE_FORMAT:-}"
  local BOOTSTRAP_CONFIRM="${BOOTSTRAP_CONFIRM:-}"
  local force=no
  case "${FORCE_FORMAT,,}" in 1|true|yes|y) force=yes ;; esac
  case "${BOOTSTRAP_CONFIRM,,}" in 1|true|yes|y) force=yes ;; esac

  if [ ! -b "$device" ]; then
    echo "ERROR: Expected block device $device not found."
    return 1
  fi

  local file_out
  file_out="$(file -s "$device" 2>/dev/null || true)"
  local is_ext4=no
  # POSIX portability: grep '\b' is GNU-only. Match ext4 as a standalone token.
  if printf '%s\n' "$file_out" | grep -qiE '(^|[^[:alnum:]_])ext4([^[:alnum:]_]|$)'; then
    is_ext4=yes
  fi

  local has_signature=no
  if command -v blkid >/dev/null 2>&1; then
    if blkid -p "$device" >/dev/null 2>&1; then
      has_signature=yes
    fi
  fi
  if command -v lsblk >/dev/null 2>&1; then
    # If there are any partitions under the device, treat it as non-empty.
    if lsblk -nr -o TYPE "$device" 2>/dev/null | grep -q '^part$'; then
      has_signature=yes
    fi
    # If lsblk reports any filesystem type on the device or its children, treat it as non-empty.
    if lsblk -nr -o FSTYPE "$device" 2>/dev/null | grep -q '[^[:space:]]'; then
      has_signature=yes
    fi
  fi
  if echo "$file_out" | grep -qiE 'filesystem|partition|LVM|xfs|btrfs|swap'; then
    has_signature=yes
  fi

  if [ "$is_ext4" != "yes" ]; then
    if [ "$has_signature" = "yes" ] && [ "$force" != "yes" ]; then
      echo "ERROR: $device appears to contain existing data or a filesystem signature:"
      echo "  $file_out"
      echo
      echo "Refusing to format automatically to avoid data loss."
      echo "If you are sure this device can be wiped, re-run with FORCE_FORMAT=1 (or BOOTSTRAP_CONFIRM=1)."
      return 1
    fi

    if [ "$has_signature" = "yes" ] && [ "$force" = "yes" ]; then
      echo "WARNING: FORCE_FORMAT/BOOTSTRAP_CONFIRM is set; formatting $device as ext4 (DATA LOSS)."
      mkfs -t ext4 -F "$device"
    elif [ "$has_signature" != "yes" ]; then
      echo "$device appears empty; formatting as ext4."
      mkfs -t ext4 -F "$device"
    fi
  fi

  mkdir -p "$mountpoint"
  grep -q "^$device $mountpoint " /etc/fstab || echo "$device $mountpoint ext4 defaults,nofail 0 2" >> /etc/fstab
  mount -a
}

