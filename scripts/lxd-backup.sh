#!/bin/bash
# LXD Backup Script for VMs & Containers
# Backups are saved to /mnt/backups
# Retention: 7 Daily, 4 Weekly (Sundays)

set -u

# Configuration
BACKUP_ROOT="/mnt/backups"
LOG_FILE="/var/log/lxd-backup.log"
MAX_LOG_LINES=5000
DAILY_DIR="${BACKUP_ROOT}/daily"
WEEKLY_DIR="${BACKUP_ROOT}/weekly"
DATE=$(date +%Y-%m-%d)
DAY_OF_WEEK=$(date +%u) # 1=Monday, 7=Sunday

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
    log "ERROR: This script must be run as root."
    exit 1
fi

# Setup Logging
if [ -f "$LOG_FILE" ]; then
    tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi
exec >> "$LOG_FILE" 2>&1

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

log "INFO: === Starting LXD Backup: $DATE ==="

# Get list of all instances across all projects
# Format: Name,Project
lxc list --all-projects --format csv -c n,P | while IFS=, read -r INSTANCE PROJECT; do
    log "INFO: Backing up instance: $INSTANCE (Project: $PROJECT)"
    
    SNAP_NAME="snap-backup-${DATE}"
    IMG_ALIAS="img-backup-${INSTANCE}-${DATE}"
    BACKUP_FILE="${DAILY_DIR}/${INSTANCE}_${DATE}.tar.gz"
    
    if [ -f "$BACKUP_FILE" ]; then
        log "INFO:   > Backup already exists for today. Skipping."
        continue
    fi
    
    # 1. Create Snapshot
    # Create a stateless snapshot (disk only, no memory state)
    lxc snapshot "$INSTANCE" "$SNAP_NAME" --project "$PROJECT"
    
    # 2. Publish Snapshot to Image
    # Creates a unified image (metadata + rootfs)
    lxc publish "$INSTANCE/$SNAP_NAME" --alias "$IMG_ALIAS" --project "$PROJECT" --compression gzip
    
    # 3. Export Image to Backup File
    lxc image export "$IMG_ALIAS" "$BACKUP_FILE" --project "$PROJECT"
    
    # 4. Cleanup Temporary Image and Snapshot
    lxc image delete "$IMG_ALIAS" --project "$PROJECT"
    lxc delete "$INSTANCE/$SNAP_NAME" --project "$PROJECT"
    
    log "INFO:   > Saved to: $BACKUP_FILE"

    # Handle Weekly Retention (Sunday)
    if [ "$DAY_OF_WEEK" -eq 7 ]; then
        log "INFO:   > Sunday detected. Copying to weekly archive..."
        cp "$BACKUP_FILE" "${WEEKLY_DIR}/${INSTANCE}_${DATE}.tar.gz"
    fi
done

log "INFO: === Running Retention Policy ==="

# Daily: Keep 7 days
log "INFO: Cleaning up daily backups older than 7 days..."
find "$DAILY_DIR" -type f -name "*.tar.gz" -mtime +7 -print -delete

# Weekly: Keep 4 copies per instance
log "INFO: Cleaning up old weekly backups (keeping latest 4)..."
# We need to re-fetch the instance list or just iterate over files in the directory to avoid complexity
find "$WEEKLY_DIR" -name "*_*.tar.gz" | sed -E 's/.*\/([^_]+)_[0-9-]+\.tar\.gz/\1/' | sort -u | while read -r INSTANCE; do
    # List files for this instance, sort by time (newest first), skip first 4, delete the rest
    ls -t "${WEEKLY_DIR}/${INSTANCE}_"*.tar.gz 2>/dev/null | tail -n +5 | xargs -r rm --
done

log "INFO: === Backup Complete ==="
