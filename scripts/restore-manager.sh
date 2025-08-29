#!/bin/bash

# PanelTK Restore Manager
# Centralized restore management system with disaster recovery capabilities

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/app/config/restore-config.yml"
LOG_FILE="/app/logs/restore-manager.log"
BACKUP_DIR="/app/backups"
RESTORE_DIR="/app/restore"
TEMP_DIR="/tmp/restore-manager"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    log "${RED}ERROR: $1${NC}"
    exit 1
}

warning() {
    log "${YELLOW}WARNING: $1${NC}"
}

success() {
    log "${GREEN}SUCCESS: $1${NC}"
}

info() {
    log "${BLUE}INFO: $1${NC}"
}

# Create necessary directories
mkdir -p "$RESTORE_DIR" "$TEMP_DIR" "$(dirname "$LOG_FILE")"

# Function to load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Loading configuration from $CONFIG_FILE"
        # Parse YAML configuration (requires yq)
        if command -v yq >/dev/null 2>&1; then
            export BACKUP_SOURCES=$(yq eval '.backup_sources' "$CONFIG_FILE")
            export DATABASE_CONFIG=$(yq eval '.database' "$CONFIG_FILE")
            export VOLUME_CONFIG=$(yq eval '.volumes' "$CONFIG_FILE")
            export ENCRYPTION_CONFIG=$(yq eval '.encryption' "$CONFIG_FILE")
            export NOTIFICATION_CONFIG=$(yq eval '.notifications' "$CONFIG_FILE")
            export RESTORE_STRATEGIES=$(yq eval '.restore_strategies' "$CONFIG_FILE")
        else
            warning "yq not found, using environment variables only"
        fi
    else
        warning "Configuration file not found, using defaults"
    fi
}

# Function to check prerequisites
check_prerequisites() {
    info "Checking prerequisites..."
    
    # Check required commands
    local required_commands=("docker" "docker-compose" "pg_restore" "redis-cli" "tar" "gzip" "rsync")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "Required command not found: $cmd"
        fi
    done
    
    # Check Docker daemon
    if ! docker info >/dev/null 2>&1; then
        error "Docker daemon is not running"
    fi
    
    # Check disk space
    local available_space=$(df /app | tail -1 | awk '{print $4}')
    local required_space=1048576  # 1GB in KB
    
    if [[ $available_space -lt $required_space ]]; then
        error "Insufficient disk space. Required: 1GB, Available: $((available_space / 1024))MB"
    fi
    
    success "All prerequisites satisfied"
}

# Function to create restore point
create_restore_point() {
    info "Creating restore point before restore operation..."
    
    local restore_point_dir="$BACKUP_DIR/restore-point-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$restore_point_dir"
    
    # Backup current state
    docker-compose exec postgres pg_dump -U paneltk panel_tk > "$restore_point_dir/database.sql"
    docker run --rm -v postgres_data:/data -v "$restore_point_dir:/backup" alpine tar czf /backup/postgres_data.tar.gz -C /data .
    docker run --rm -v redis_data:/data -v "$restore_point_dir:/backup" alpine tar czf /backup/redis_data.tar.gz -C /data .
    docker run --rm -v uploads:/data -v "$restore_point_dir:/backup" alpine tar czf /backup/uploads.tar.gz -C /data .
    
    echo "$restore_point_dir" > "$RESTORE_DIR/last-restore-point"
    
    success "Restore point created: $restore_point_dir"
}

# Function to download backup
download_backup() {
    local backup_source="$1"
    local backup_path="$2"
    
    info "Downloading backup from $backup_source..."
    
    case "$backup_source" in
        "local")
            if [[ -f "$backup_path" ]]; then
                cp "$backup_path" "$TEMP_DIR/backup.tar.gz"
            else
                error "Local backup not found: $backup_path"
            fi
            ;;
        "s3")
            if [[ -n "${S3_BUCKET:-}" ]]; then
                aws s3 cp "s3://${S3_BUCKET}/${backup_path}" "$TEMP_DIR/backup.tar.gz"
            else
                error "S3 configuration missing"
            fi
            ;;
        "gcs")
            if [[ -n "${GCS_BUCKET:-}" ]]; then
                gsutil cp "gs://${GCS_BUCKET}/${backup_path}" "$TEMP_DIR/backup.tar.gz"
            else
                error "GCS configuration missing"
            fi
            ;;
        "azure")
            if [[ -n "${AZURE_CONTAINER:-}" ]]; then
                az storage blob download --container-name "$AZURE_CONTAINER" --name "$backup_path" --file "$TEMP_DIR/backup.tar.gz"
            else
                error "Azure configuration missing"
            fi
            ;;
        "ftp")
            if [[ -n "${FTP_HOST:-}" ]]; then
                curl -o "$TEMP_DIR/backup.tar.gz" "ftp://${FTP_USERNAME}:${FTP_PASSWORD}@${FTP_HOST}/${backup_path}"
            else
                error "FTP configuration missing"
            fi
            ;;
        "sftp")
            if [[ -n "${SFTP_HOST:-}" ]]; then
                sftp "${SFTP_USERNAME}@${SFTP_HOST}:${backup_path}" "$TEMP_DIR/backup.tar.gz"
            else
                error "SFTP configuration missing"
            fi
            ;;
        *)
            error "Unsupported backup source: $backup_source"
            ;;
    esac
    
    success "Backup downloaded successfully"
}

# Function to decrypt backup
decrypt_backup() {
    local encrypted_file="$1"
    local decrypted_file="$2"
    
    if [[ "${ENCRYPTION_ENABLED:-false}" == "true" ]]; then
        info "Decrypting backup..."
        
        local key="${ENCRYPTION_KEY:-}"
        if [[ -z "$key" ]]; then
            error "Encryption enabled but no key provided"
        fi
        
        openssl enc -d -aes-256-cbc -in "$encrypted_file" -out "$decrypted_file" -k "$key"
        
        success "Backup decrypted successfully"
    else
        mv "$encrypted_file" "$decrypted_file"
    fi
}

# Function to restore database
restore_database() {
    info "Restoring database..."
    
    # Stop application services
    docker-compose stop app nginx
    
    # Restore PostgreSQL
    if [[ -f "$TEMP_DIR/database/postgres_backup.sql" ]]; then
        docker-compose exec -T postgres psql -U paneltk -d postgres -c "DROP DATABASE IF EXISTS panel_tk;"
        docker-compose exec -T postgres psql -U paneltk -d postgres -c "CREATE DATABASE panel_tk;"
        docker-compose exec -T postgres psql -U paneltk -d panel_tk < "$TEMP_DIR/database/postgres_backup.sql"
    fi
    
    # Restore Redis
    if [[ -f "$TEMP_DIR/database/redis_backup.rdb" ]]; then
        docker-compose stop redis
        docker run --rm -v redis_data:/data -v "$TEMP_DIR/database:/backup" alpine cp /backup/redis_backup.rdb /data/dump.rdb
        docker-compose start redis
    fi
    
    success "Database restored successfully"
}

# Function to restore volumes
restore_volumes() {
    info "Restoring volumes..."
    
    local volumes=("postgres_data" "redis_data" "uploads" "ssl_certs")
    
    for volume in "${volumes[@]}"; do
        local volume_file="$TEMP_DIR/volumes/${volume}.tar.gz"
        if [[ -f "$volume_file" ]]; then
            docker run --rm -v "${volume}:/data" -v "$TEMP_DIR/volumes:/backup" alpine tar xzf "/backup/${volume}.tar.gz" -C /data
            success "Volume restored: $volume"
        else
            warning "Volume backup not found: $volume"
        fi
    done
}

# Function to restore configuration
restore_configuration() {
    info "Restoring configuration..."
    
    if [[ -f "$TEMP_DIR/config/app_config.json" ]]; then
        cp "$TEMP_DIR/config/app_config.json" /app/config/
        success "Configuration restored"
    fi
    
    if [[ -f "$TEMP_DIR/ssl_certs" ]]; then
        cp -r "$TEMP_DIR/ssl_certs" /etc/ssl/
        success "SSL certificates restored"
    fi
}

# Function to run health checks
run_health_checks() {
    info "Running health checks..."
    
    local health_check_timeout="${HEALTH_CHECK_TIMEOUT:-300}"
    local health_check_retries="${HEALTH_CHECK_RETRIES:-5}"
    
    # Check application
    local app_url="${APP_URL:-http://localhost}/api/health"
    for i in $(seq 1 "$health_check_retries"); do
        if curl -f "$app_url" >/dev/null 2>&1; then
            success "Application health check passed"
            break
        fi
        
        if [[ $i -eq $health_check_retries ]]; then
            error "Application health check failed"
        fi
        
        sleep 10
    done
    
    # Check database
    if docker-compose exec postgres pg_isready -U paneltk -d panel_tk >/dev/null 2>&1; then
        success "Database health check passed"
    else
        error "Database health check failed"
    fi
    
    # Check Redis
    if docker-compose exec redis redis-cli ping >/dev/null 2>&1; then
        success "Redis health check passed"
    else
        error "Redis health check failed"
    fi
    
    success "All health checks passed"
}

# Function to send notifications
send_notification() {
    local status="$1"
    local message="$2"
    
    info "Sending notifications..."
    
    # Slack notification
    if [[ "${SLACK_ENABLED:-false}" == "true" ]]; then
        curl -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"PanelTK Restore: $status - $message\"}" \
            "${SLACK_WEBHOOK:-}"
    fi
    
    # Discord notification
    if [[ "${DISCORD_ENABLED:-false}" == "true" ]]; then
        curl -X POST -H 'Content-type: application/json' \
            --data "{\"content\":\"PanelTK Restore: $status - $message\"}" \
            "${DISCORD_WEBHOOK:-}"
    fi
    
    # Email notification
    if [[ "${EMAIL_ENABLED:-false}" == "true" ]]; then
        echo "$message" | mail -s "PanelTK Restore: $status" "${EMAIL_TO:-admin@paneltk.com}"
    fi
    
    success "Notifications sent"
}

# Function to rollback on failure
rollback_on_failure() {
    error "Restore failed, initiating rollback..."
    
    local restore_point=$(cat "$RESTORE_DIR/last-restore-point" 2>/dev/null || echo "")
    
    if [[ -n "$restore_point" && -d "$restore_point" ]]; then
        info "Rolling back to restore point: $restore_point"
        
        # Restore from restore point
        docker-compose exec postgres psql -U paneltk panel_tk < "$restore_point/database.sql"
        docker run --rm -v postgres_data:/data -v "$restore_point:/backup" alpine tar xzf /backup/postgres_data.tar.gz -C /data
        docker run --rm -v redis_data:/data -v "$restore_point:/backup" alpine tar xzf /backup/redis_data.tar.gz -C /data
        docker run --rm -v uploads:/data -v "$restore_point:/backup" alpine tar xzf /backup/uploads.tar.gz -C /data
        
        success "Rollback completed"
    else
        error "No restore point available for rollback"
    fi
}

# Function to execute restore strategy
execute_restore_strategy() {
    local strategy="$1"
    
    info "Executing restore strategy: $strategy"
    
    case "$strategy" in
        "full_restore")
            restore_database
            restore_volumes
            restore_configuration
            ;;
        "database_only")
            restore_database
            ;;
        "volumes_only")
            restore_volumes
            ;;
        "config_only")
            restore_configuration
            ;;
        "disaster_recovery")
            restore_database
            restore_volumes
            restore_configuration
            # Additional disaster recovery steps
            ;;
        *)
            error "Unknown restore strategy: $strategy"
            ;;
    esac
}

# Main restore function
main() {
    local backup_source="${1:-local}"
    local backup_path="${2:-latest}"
    local strategy="${3:-full_restore}"
    
    log "Starting restore operation..."
    log "Source: $backup_source"
    log "Path: $backup_path"
    log "Strategy: $strategy"
    
    # Load configuration
    load_config
    
    # Check prerequisites
    check_prerequisites
    
    # Create restore point
    create_restore_point
    
    # Download backup
    download_backup "$backup_source" "$backup_path"
    
    # Validate backup
    if ! /app/scripts/validate-backup.sh; then
        error "Backup validation failed"
    fi
    
    # Decrypt backup
    decrypt_backup "$TEMP_DIR/backup.tar.gz" "$TEMP_DIR/decrypted_backup.tar.gz"
    
    # Extract backup
    mkdir -p "$TEMP_DIR/extracted"
    tar -xzf "$TEMP_DIR/decrypted_backup.tar.gz" -C "$TEMP_DIR/extracted"
    
    # Execute restore strategy
    if execute_restore_strategy "$strategy"; then
        # Run health checks
        run_health_checks
        
        # Send success notification
        send_notification "SUCCESS" "Restore completed successfully"
        
        success "Restore operation completed successfully"
    else
        # Send failure notification
        send_notification "FAILED" "Restore operation failed"
        
        # Rollback on failure
        rollback_on_failure
        
        error "Restore operation failed"
    fi
    
    # Cleanup
    rm -rf "$TEMP_DIR"
}

# Handle command line arguments
case "${1:-}" in
    "restore")
        main "${2:-}" "${3:-}" "${4:-}"
        ;;
    "validate")
        /app/scripts/validate-backup.sh
        ;;
    "rollback")
        rollback_on_failure
        ;;
    "health-check")
        run_health_checks
        ;;
    *)
        echo "Usage: $0 {restore|validate|rollback|health-check} [source] [path] [strategy]"
        echo "Strategies: full_restore, database_only, volumes_only, config_only, disaster_recovery"
        exit 1
        ;;
esac
