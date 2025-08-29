#!/bin/bash

# PanelTK Restore Script
# Comprehensive restore solution for PanelTK installations
# Supports full system restore, selective restore, and various backup sources

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/restore.conf}"
LOG_FILE="${LOG_FILE:-/var/log/panel-tk/restore.log}"
TEMP_DIR="${TEMP_DIR:-/tmp/panel-tk-restore}"
BACKUP_DIR="${BACKUP_DIR:-/opt/panel-tk/backups}"

# Default values
DRY_RUN=false
INTERACTIVE=false
CONFIRM=false
VERBOSE=false
DEBUG=false
TEST_MODE=false
VERIFY=true
CLEANUP=true
FULL_RESTORE=false
DATABASE_ONLY=false
FILES_ONLY=false
CONFIG_ONLY=false
ENCRYPTED=false
SKIP_SERVICES=false

# Database configuration
DB_NAME="${DB_NAME:-panel_tk}"
DB_USER="${DB_USER:-paneltk}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"

# Redis configuration
REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log "Configuration loaded from $CONFIG_FILE"
    else
        warning "Configuration file not found: $CONFIG_FILE"
    fi
}

# Logging functions
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[$timestamp]${NC} $message" | tee -a "$LOG_FILE"
}

error() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[$timestamp] ERROR:${NC} $message" | tee -a "$LOG_FILE"
}

warning() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[$timestamp] WARNING:${NC} $message" | tee -a "$LOG_FILE"
}

debug() {
    local message="$1"
    if [[ "$DEBUG" == "true" ]]; then
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo -e "${BLUE}[$timestamp] DEBUG:${NC} $message" | tee -a "$LOG_FILE"
    fi
}

# Check dependencies
check_dependencies() {
    local deps=("tar" "gzip" "psql" "redis-cli" "docker" "docker-compose")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
        exit 1
    fi
    
    log "All dependencies satisfied"
}

# Create directories
create_directories() {
    mkdir -p "$TEMP_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    mkdir -p "$BACKUP_DIR"
    log "Directories created"
}

# Download backup if remote
download_backup() {
    local backup_path="$1"
    local local_path="$2"
    
    if [[ "$backup_path" =~ ^https?:// ]]; then
        log "Downloading backup from URL: $backup_path"
        if command -v curl &> /dev/null; then
            curl -L -o "$local_path" "$backup_path"
        elif command -v wget &> /dev/null; then
            wget -O "$local_path" "$backup_path"
        else
            error "Neither curl nor wget found for downloading"
            exit 1
        fi
    elif [[ "$backup_path" =~ ^s3:// ]]; then
        log "Downloading from S3: $backup_path"
        if command -v aws &> /dev/null; then
            aws s3 cp "$backup_path" "$local_path"
        else
            error "AWS CLI not found for S3 download"
            exit 1
        fi
    elif [[ "$backup_path" =~ ^ftp:// ]]; then
        log "Downloading from FTP: $backup_path"
        if command -v lftp &> /dev/null; then
            lftp -c "get $backup_path -o $local_path"
        else
            error "lftp not found for FTP download"
            exit 1
        fi
    else
        # Local file
        if [[ ! -f "$backup_path" ]]; then
            error "Backup file not found: $backup_path"
            exit 1
        fi
        cp "$backup_path" "$local_path"
    fi
}

# Verify backup integrity
verify_backup() {
    local backup_path="$1"
    
    if [[ "$VERIFY" != "true" ]]; then
        warning "Skipping backup verification"
        return 0
    fi
    
    log "Verifying backup integrity..."
    
    if ! tar -tzf "$backup_path" &> /dev/null; then
        error "Backup file is corrupted or invalid"
        return 1
    fi
    
    # Check for required files
    local required_files=("backup_metadata.json")
    for file in "${required_files[@]}"; do
        if ! tar -tzf "$backup_path" | grep -q "$file"; then
            error "Required file missing in backup: $file"
            return 1
        fi
    done
    
    log "Backup verification completed successfully"
}

# Extract backup
extract_backup() {
    local backup_path="$1"
    local extract_dir="$2"
    
    log "Extracting backup to $extract_dir..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: Would extract backup to $extract_dir"
        return 0
    fi
    
    mkdir -p "$extract_dir"
    tar -xzf "$backup_path" -C "$extract_dir"
    
    log "Backup extracted successfully"
}

# Stop services
stop_services() {
    if [[ "$SKIP_SERVICES" == "true" ]]; then
        log "Skipping service stop"
        return 0
    fi
    
    log "Stopping services..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: Would stop services"
        return 0
    fi
    
    cd "$PROJECT_ROOT"
    docker-compose down
    
    # Stop PostgreSQL if running locally
    if systemctl is-active --quiet postgresql; then
        sudo systemctl stop postgresql
    fi
    
    # Stop Redis if running locally
    if systemctl is-active --quiet redis; then
        sudo systemctl stop redis
    fi
    
    log "Services stopped"
}

# Start services
start_services() {
    if [[ "$SKIP_SERVICES" == "true" ]]; then
        log "Skipping service start"
        return 0
    fi
    
    log "Starting services..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: Would start services"
        return 0
    fi
    
    cd "$PROJECT_ROOT"
    docker-compose up -d
    
    # Wait for services to be ready
    log "Waiting for services to be ready..."
    sleep 30
    
    log "Services started"
}

# Restore database
restore_database() {
    local backup_dir="$1"
    
    if [[ "$DATABASE_ONLY" != "true" && "$FILES_ONLY" == "true" ]]; then
        log "Skipping database restore (files-only mode)"
        return 0
    fi
    
    local db_dump="$backup_dir/database/panel_tk.sql"
    
    if [[ ! -f "$db_dump" ]]; then
        warning "Database dump not found: $db_dump"
        return 0
    fi
    
    log "Restoring database..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: Would restore database from $db_dump"
        return 0
    fi
    
    # Create database if it doesn't exist
    PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "CREATE DATABASE IF NOT EXISTS $DB_NAME;" 2>/dev/null || true
    
    # Restore database
    PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" < "$db_dump"
    
    log "Database restored successfully"
}

# Restore files
restore_files() {
    local backup_dir="$1"
    
    if [[ "$FILES_ONLY" != "true" && "$DATABASE_ONLY" == "true" ]]; then
        log "Skipping file restore (database-only mode)"
        return 0
    fi
    
    log "Restoring files..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: Would restore files from $backup_dir"
        return 0
    fi
    
    # Restore application files
    if [[ -d "$backup_dir/files" ]]; then
        cp -r "$backup_dir/files"/* "$PROJECT_ROOT/"
    fi
    
    # Restore configuration
    if [[ -d "$backup_dir/config" ]]; then
        cp -r "$backup_dir/config"/* "$PROJECT_ROOT/config/"
    fi
    
    # Restore uploads
    if [[ -d "$backup_dir/uploads" ]]; then
        cp -r "$backup_dir/uploads"/* "$PROJECT_ROOT/uploads/"
    fi
    
    log "Files restored successfully"
}

# Restore configuration
restore_configuration() {
    local backup_dir="$1"
    
    if [[ "$CONFIG_ONLY" != "true" ]]; then
        return 0
    fi
    
    log "Restoring configuration..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: Would restore configuration from $backup_dir"
        return 0
    fi
    
    if [[ -d "$backup_dir/config" ]]; then
        cp -r "$backup_dir/config"/* "$PROJECT_ROOT/config/"
        log "Configuration restored successfully"
    else
        warning "Configuration directory not found in backup"
    fi
}

# Fix permissions
fix_permissions() {
    log "Fixing file permissions..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: Would fix file permissions"
        return 0
    fi
    
    # Fix ownership
    if [[ -n "${SUDO_USER:-}" ]]; then
        chown -R "$SUDO_USER:$SUDO_USER" "$PROJECT_ROOT"
    fi
    
    # Fix file permissions
    find "$PROJECT_ROOT" -type f -exec chmod 644 {} \;
    find "$PROJECT_ROOT" -type d -exec chmod 755 {} \;
    
    # Make scripts executable
    find "$PROJECT_ROOT/scripts" -type f -name "*.sh" -exec chmod +x {} \;
    
    log "File permissions fixed"
}

# Cleanup
cleanup() {
    if [[ "$CLEANUP" != "true" ]]; then
        log "Skipping cleanup"
        return 0
    fi
    
    log "Cleaning up temporary files..."
    
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    
    log "Cleanup completed"
}

# Send notifications
send_notification() {
    local status="$1"
    local message="$2"
    
    # Email notification
    if [[ "${NOTIFY_ON_RESTORE:-false}" == "true" && -n "${NOTIFY_EMAIL:-}" ]]; then
        echo "$message" | mail -s "PanelTK Restore $status" "$NOTIFY_EMAIL"
    fi
    
    # Webhook notification
    if [[ -n "${NOTIFY_WEBHOOK:-}" ]]; then
        curl -X POST -H "Content-Type: application/json" \
             -d "{\"text\":\"PanelTK Restore $status: $message\"}" \
             "$NOTIFY_WEBHOOK"
    fi
}

# Interactive mode
interactive_mode() {
    if [[ "$INTERACTIVE" != "true" ]]; then
        return 0
    fi
    
    echo "PanelTK Restore - Interactive Mode"
    echo "=================================="
    echo
    echo "This will restore your PanelTK installation from backup."
    echo "Current configuration:"
    echo "  Backup: $BACKUP_PATH"
    echo "  Database: $DB_NAME@$DB_HOST:$DB_PORT"
    echo "  Project: $PROJECT_ROOT"
    echo
    
    read -p "Do you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Restore cancelled by user"
        exit 0
    fi
    
    if [[ "$CONFIRM" == "true" ]]; then
        read -p "Are you sure? This will overwrite existing data. (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Restore cancelled by user"
            exit 0
        fi
    fi
}

# Test mode
test_mode() {
    if [[ "$TEST_MODE" != "true" ]]; then
        return 0
    fi
    
    log "Running in test mode - no actual changes will be made"
    DRY_RUN=true
    SKIP_SERVICES=true
    CLEANUP=false
}

# Main restore function
perform_restore() {
    local backup_path="$1"
    local temp_extract_dir="$TEMP_DIR/extracted"
    
    log "Starting restore process..."
    log "Backup: $backup_path"
    log "Project: $PROJECT_ROOT"
    
    # Download backup if remote
    local local_backup="$TEMP_DIR/backup.tar.gz"
    download_backup "$backup_path" "$local_backup"
    
    # Verify backup
    verify_backup "$local_backup"
    
    # Interactive mode
    interactive_mode
    
    # Stop services
    stop_services
    
    # Extract backup
    extract_backup "$local_backup" "$temp_extract_dir"
    
    # Restore components
    restore_database "$temp_extract_dir"
    restore_files "$temp_extract_dir"
    restore_configuration "$temp_extract_dir"
    
    # Fix permissions
    fix_permissions
    
    # Start services
    start_services
    
    # Cleanup
    cleanup
    
    log "Restore completed successfully!"
    send_notification "SUCCESS" "Restore completed successfully from $backup_path"
}

# List backup contents
list_backup() {
    local backup_path="$1"
    local local_backup="$TEMP_DIR/backup.tar.gz"
    
    download_backup "$backup_path" "$local_backup"
    verify_backup "$local_backup"
    
    echo "Backup contents:"
    tar -tzf "$local_backup"
}

# Show backup info
show_backup_info() {
    local backup_path="$1"
    local local_backup="$TEMP_DIR/backup.tar.gz"
    
    download_backup "$backup_path" "$local_backup"
    verify_backup "$local_backup"
    
    local temp_dir="$TEMP_DIR/info"
    mkdir -p "$temp_dir"
    tar -xzf "$local_backup" -C "$temp_dir" "backup_metadata.json"
    
    if [[ -f "$temp_dir/backup_metadata.json" ]]; then
        echo "Backup Information:"
        cat "$temp_dir/backup_metadata.json" | jq .
    else
        echo "No metadata found in backup"
    fi
    
    rm -rf "$temp_dir"
}

# Usage information
usage() {
    cat << EOF
PanelTK Restore Script

Usage: $0 [OPTIONS] BACKUP_PATH

Options:
    -h, --help              Show this help message
    -c, --config FILE       Configuration file path
    -d, --dry-run           Show what would be done without executing
    -i, --interactive       Interactive mode with prompts
    -y, --confirm           Confirm before proceeding
    -v, --verbose           Verbose output
    --debug                 Debug output
    --test-mode             Test mode (no actual changes)
    --skip-verify           Skip backup verification
    --no-cleanup            Skip cleanup after restore
    --full                  Full system restore
    --database-only         Restore database only
    --files-only            Restore files only
    --config-only           Restore configuration only
    --skip-services         Skip service management
    --list                  List backup contents
    --info                  Show backup information
    --verify                Verify backup integrity only

Examples:
    $0 /path/to/backup.tar.gz
    $0 --dry-run /path/to/backup.tar.gz
    $0 --interactive --confirm /path/to/backup.tar.gz
    $0 --database-only s3://bucket/backup.tar.gz
    $0 --list /path/to/backup.tar.gz
    $0 --info https://example.com/backup.tar.gz
EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -i|--interactive)
                INTERACTIVE=true
                shift
                ;;
            -y|--confirm)
                CONFIRM=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            --test-mode)
                TEST_MODE=true
                shift
                ;;
            --skip-verify)
                VERIFY=false
                shift
                ;;
            --no-cleanup)
                CLEANUP=false
                shift
                ;;
            --full)
                FULL_RESTORE=true
                shift
                ;;
            --database-only)
                DATABASE_ONLY=true
                shift
                ;;
            --files-only)
                FILES_ONLY=true
                shift
                ;;
            --config-only)
                CONFIG_ONLY=true
                shift
                ;;
            --skip-services)
                SKIP_SERVICES=true
                shift
                ;;
            --list)
                LIST_ONLY=true
                shift
                ;;
            --info)
                INFO_ONLY=true
                shift
                ;;
            --verify)
                VERIFY_ONLY=true
                shift
                ;;
            -*)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                BACKUP_PATH="$1"
                shift
                ;;
        esac
    done
    
    if [[ -z "${BACKUP_PATH:-}" && "$LIST_ONLY" != "true" && "$INFO_ONLY" != "true" ]]; then
        error "Backup path is required"
        usage
        exit 1
    fi
}

# Main execution
main() {
    parse_args "$@"
    
    # Load configuration
    load_config
    
    # Create directories
    create_directories
    
    # Check dependencies
    check_dependencies
    
    # Handle special modes
    if [[ "$LIST_ONLY" == "true" ]]; then
        list_backup "$BACKUP_PATH"
        exit 0
    fi
    
    if [[ "$INFO_ONLY" == "true" ]]; then
        show_backup_info "$BACKUP_PATH"
        exit 0
    fi
    
    if [[ "$VERIFY_ONLY" == "true" ]]; then
        local local_backup="$TEMP_DIR/backup.tar.gz"
        download_backup "$BACKUP_PATH" "$local_backup"
        verify_backup "$local_backup"
        log "Backup verification completed"
        exit 0
    fi
    
    # Test mode
    test_mode
    
    # Perform restore
    perform_restore "$BACKUP_PATH"
}

# Execute main function
main "$@"
