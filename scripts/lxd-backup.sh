#!/bin/bash
# LXD Backup Script for VMs & Containers
# Backups are saved to /mnt/backups (configurable via LXD_BACKUP_ROOT)
# Retention: 7 Daily, 4 Weekly (Sundays)

set -uo pipefail

# Error trapping
trap 'log "ERROR: Script failed at line $LINENO"' ERR

# Configuration (can be overridden via environment variables)
BACKUP_ROOT="${LXD_BACKUP_ROOT:-/mnt/backups}"
LOG_FILE="${LXD_BACKUP_LOG:-/var/log/lxd-backup.log}"
# Compression: gzip (slow, good ratio), zstd (fast, good ratio), lz4 (fastest, lower ratio)
COMPRESSION="${LXD_BACKUP_COMPRESSION:-zstd}"
MAX_LOG_LINES=5000
DAILY_DIR="${BACKUP_ROOT}/daily"
WEEKLY_DIR="${BACKUP_ROOT}/weekly"
DATE=$(date +%Y-%m-%d)
DAY_OF_WEEK=$(date +%u) # 1=Monday, 7=Sunday

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
    log "ERROR: This script must be run as root."
    exit 1
fi

# Setup Logging
touch "$LOG_FILE" 2>/dev/null || true
if [ -f "$LOG_FILE" ]; then
    tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

# Check for lxc command
if ! command -v lxc &> /dev/null; then
    log "ERROR: 'lxc' command not found."
    exit 1
fi

# Check if backup destination is mounted
if ! mountpoint -q "$BACKUP_ROOT"; then
    log "ERROR: $BACKUP_ROOT is not a mountpoint. Please mount the NFS share."
    exit 1
fi

# Create backup directories
mkdir -p "$DAILY_DIR" "$WEEKLY_DIR"

# Check available disk space (require at least 50GB)
MIN_SPACE_GB="${LXD_BACKUP_MIN_SPACE_GB:-50}"
AVAILABLE_KB=$(df "$BACKUP_ROOT" | tail -1 | awk '{print $4}')
if [ "$AVAILABLE_KB" -lt $((MIN_SPACE_GB * 1024 * 1024)) ]; then
    log "ERROR: Insufficient disk space. Required: ${MIN_SPACE_GB}GB, Available: $((AVAILABLE_KB / 1024 / 1024))GB"
    exit 1
fi

log "INFO: === Starting LXD Backup: $DATE ==="

# Get list of all instances across all projects
# Format: Name,Project
while IFS=, read -r INSTANCE PROJECT; do
    log "INFO: Backing up instance: $INSTANCE (Project: $PROJECT)"
    
    # Use timestamp to avoid Ceph/RBD collisions on retries
    TS=$(date +%H%M%S)
    SNAP_NAME="snap-backup-${DATE}-${TS}"
    IMG_ALIAS="img-backup-${INSTANCE}-${DATE}-${TS}"
    # Note: lxc image export automatically adds .tar.gz extension
    BACKUP_FILE="${DAILY_DIR}/${INSTANCE}_${DATE}"
    
    # Check for existing backup (handles both old double-extension and new correct format)
    if [ -f "${BACKUP_FILE}.tar.gz" ] || [ -f "${BACKUP_FILE}.tar.gz.tar.gz" ]; then
        log "INFO:   > Backup already exists for today. Skipping."
        continue
    fi
    
    # Pre-cleanup: Remove potential leftovers from failed runs
    lxc image delete "$IMG_ALIAS" --project "$PROJECT" >/dev/null 2>&1 || true
    lxc delete "$INSTANCE/$SNAP_NAME" --project "$PROJECT" >/dev/null 2>&1 || true
    
    # 1. Create Snapshot
    # Create a stateless snapshot (disk only, no memory state)
    log "INFO:   > Creating snapshot..."
    if ! timeout 300 lxc snapshot "$INSTANCE" "$SNAP_NAME" --project "$PROJECT" < /dev/null; then
        log "ERROR: Failed to create snapshot for $INSTANCE. Skipping."
        continue
    fi
    
    # 2. Publish Snapshot to Image
    # Creates a unified image (metadata + rootfs)
    log "INFO:   > Publishing image (compression: $COMPRESSION)..."
    if ! timeout 7200 lxc publish "$INSTANCE/$SNAP_NAME" --alias "$IMG_ALIAS" --project "$PROJECT" --compression "$COMPRESSION" < /dev/null; then
        log "ERROR: Failed to publish image for $INSTANCE. Cleaning up snapshot."
        lxc delete "$INSTANCE/$SNAP_NAME" --project "$PROJECT" >/dev/null 2>&1 || true
        continue
    fi
    
    # 3. Export Image to Backup File
    EXPORT_SUCCESS=true
    log "INFO:   > Exporting image to file..."
    if ! timeout 3600 lxc image export "$IMG_ALIAS" "$BACKUP_FILE" --project "$PROJECT" < /dev/null; then
        log "ERROR: Failed to export image for $INSTANCE."
        EXPORT_SUCCESS=false
    else
        log "INFO:   > Saved to: ${BACKUP_FILE}.tar.gz"
    fi
    
    # 4. Cleanup Temporary Image and Snapshot
    lxc image delete "$IMG_ALIAS" --project "$PROJECT" >/dev/null 2>&1 || true
    lxc delete "$INSTANCE/$SNAP_NAME" --project "$PROJECT" >/dev/null 2>&1 || true

    [ "$EXPORT_SUCCESS" = "false" ] && continue

    # Handle Weekly Retention (Sunday)
    if [ "$DAY_OF_WEEK" -eq 7 ]; then
        log "INFO:   > Sunday detected. Copying to weekly archive..."
        if ! cp "${BACKUP_FILE}.tar.gz" "${WEEKLY_DIR}/${INSTANCE}_${DATE}.tar.gz"; then
            log "ERROR: Failed to copy weekly backup for $INSTANCE"
        fi
    fi
done < <(lxc list --all-projects --format csv -c n,P | sort -u)

log "INFO: === Running Retention Policy ==="

# Daily: Keep 7 days
log "INFO: Cleaning up daily backups older than 7 days..."
find "$DAILY_DIR" -type f -name "*.tar.gz" -mtime +7 -print -delete

# Weekly: Keep 4 copies per instance
log "INFO: Cleaning up old weekly backups (keeping latest 4)..."
# Extract instance names by removing the date suffix (handles underscores in names)
# Pattern: INSTANCE_YYYY-MM-DD.tar.gz -> extract everything before _YYYY-MM-DD
find "$WEEKLY_DIR" -name "*_[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].tar.gz" -printf '%f\n' | \
    sed -E 's/_[0-9]{4}-[0-9]{2}-[0-9]{2}\.tar\.gz$//' | sort -u | while read -r INSTANCE; do
    # List files for this instance, sort by time (newest first), skip first 4, delete the rest
    ls -t "${WEEKLY_DIR}/${INSTANCE}_"*.tar.gz 2>/dev/null | tail -n +5 | xargs -r rm --
done

log "INFO: === Backup Complete ==="
