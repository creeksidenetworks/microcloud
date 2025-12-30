#!/bin/bash
# LXD Backup Script for VMs & Containers
# Backups are saved to /mnt/backups
# Retention: 7 Daily, 4 Weekly (Sundays)

set -u

# Configuration
BACKUP_ROOT="/mnt/backups"
DAILY_DIR="${BACKUP_ROOT}/daily"
WEEKLY_DIR="${BACKUP_ROOT}/weekly"
DATE=$(date +%Y-%m-%d)
DAY_OF_WEEK=$(date +%u) # 1=Monday, 7=Sunday

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# Check for lxc command
if ! command -v lxc &> /dev/null; then
    echo "Error: 'lxc' command not found."
    exit 1
fi

# Check if backup destination is mounted
if ! mountpoint -q "$BACKUP_ROOT"; then
    echo "Error: $BACKUP_ROOT is not a mountpoint. Please mount the NFS share."
    exit 1
fi

# Create backup directories
mkdir -p "$DAILY_DIR" "$WEEKLY_DIR"

echo "=== Starting LXD Backup: $DATE ==="

# Get list of all instances across all projects
# Format: Name,Project
lxc list --all-projects --format csv -c n,P | while IFS=, read -r INSTANCE PROJECT; do
    echo "Backing up instance: $INSTANCE (Project: $PROJECT)"
    
    SNAP_NAME="snap-backup-${DATE}"
    IMG_ALIAS="img-backup-${INSTANCE}-${DATE}"
    BACKUP_FILE="${DAILY_DIR}/${INSTANCE}_${DATE}.tar.gz"
    
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
    
    echo "  > Saved to: $BACKUP_FILE"

    # Handle Weekly Retention (Sunday)
    if [ "$DAY_OF_WEEK" -eq 7 ]; then
        echo "  > Sunday detected. Copying to weekly archive..."
        cp "$BACKUP_FILE" "${WEEKLY_DIR}/${INSTANCE}_${DATE}.tar.gz"
    fi
done

echo "=== Running Retention Policy ==="

# Daily: Keep 7 days
echo "Cleaning up daily backups older than 7 days..."
find "$DAILY_DIR" -type f -name "*.tar.gz" -mtime +7 -print -delete

# Weekly: Keep 4 copies per instance
echo "Cleaning up old weekly backups (keeping latest 4)..."
# We need to re-fetch the instance list or just iterate over files in the directory to avoid complexity
find "$WEEKLY_DIR" -name "*_*.tar.gz" | sed -E 's/.*\/([^_]+)_[0-9-]+\.tar\.gz/\1/' | sort -u | while read -r INSTANCE; do
    # List files for this instance, sort by time (newest first), skip first 4, delete the rest
    ls -t "${WEEKLY_DIR}/${INSTANCE}_"*.tar.gz 2>/dev/null | tail -n +5 | xargs -r rm --
done

echo "=== Backup Complete ==="
