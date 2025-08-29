#!/bin/bash
# PanelTK Backup Script
# Comprehensive backup solution for PanelTK infrastructure

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="/opt/panel-tk/config/backup.conf"
LOG_FILE="/var/log/panel-tk/backup.log"
BACKUP_DIR="/opt/panel-tk/backups"
TEMP_DIR="/tmp/panel-tk-backup"
RETENTION_DAYS=30
COMPRESSION_LEVEL=6

# Default settings
BACKUP_DATABASE=true
BACKUP_FILES=true
BACKUP_DOCKER_VOLUMES=true
BACKUP_CONFIGS=true
BACKUP_LOGS=false
ENCRYPT_BACKUP=false
ENCRYPTION_KEY_FILE="/opt/panel-tk/config/backup.key"
REMOTE_BACKUP=false
REMOTE_HOST=""
REMOTE_USER=""
REMOTE_PATH=""
S3_BACKUP=false
S3_BUCKET=""
S3_REGION="us-east-1"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

# Load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    fi
    
    # Override with environment variables
    [[ -n "${BACKUP_RETENTION_DAYS:-}" ]] && RETENTION_DAYS="$BACKUP_RETENTION_DAYS"
    [[ -n "${BACKUP_COMPRESSION_LEVEL:-}" ]] && COMPRESSION_LEVEL="$BACKUP_COMPRESSION_LEVEL"
    [[ -n "${BACKUP_ENCRYPT:-}" ]] && ENCRYPT_BACKUP="$BACKUP_ENCRYPT"
    [[ -n "${BACKUP_REMOTE:-}" ]] && REMOTE_BACKUP="$BACKUP_REMOTE"
    [[ -n "${BACKUP_S3:-}" ]] && S3_BACKUP="$BACKUP_S3"
}

# Initialize backup
init_backup() {
    mkdir -p "$(dirname "$LOG_FILE")"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$TEMP_DIR"
    
    # Load environment
    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        source "$PROJECT_ROOT/.env"
    fi
    
    load_config
    
    # Create backup directory structure
    local backup_date=$(date +%Y%m%d_%H%M%S)
    local backup_path="$BACKUP_DIR/$backup_date"
    mkdir -p "$backup_path"
    
    echo "$backup_path"
}

# Backup database
backup_database() {
    local backup_path="$1"
    local db_backup_dir="$backup_path/database"
    mkdir -p "$db_backup_dir"
    
    info "Starting database backup..."
    
    # PostgreSQL backup
    if command -v pg_dump &> /dev/null; then
        local db_name="${DB_NAME:-panel_tk}"
        local db_user="${DB_USER:-paneltk}"
        local db_host="${DB_HOST:-localhost}"
        local db_port="${DB_PORT:-5432}"
        
        PGPASSWORD="${DB_PASSWORD:-}" pg_dump \
            -h "$db_host" \
            -p "$db_port" \
            -U "$db_user" \
            -d "$db_name" \
            --verbose \
            --clean \
            --if-exists \
            --create \
            --format=custom \
            > "$db_backup_dir/postgresql_backup.dump"
        
        success "PostgreSQL backup completed"
    else
        warning "PostgreSQL not found, skipping database backup"
    fi
    
    # Redis backup (if applicable)
    if command -v redis-cli &> /dev/null; then
        local redis_host="${REDIS_HOST:-localhost}"
        local redis_port="${REDIS_PORT:-6379}"
        
        redis-cli -h "$redis_host" -p "$redis_port" BGSAVE 2>/dev/null || true
        sleep 2
        
        local redis_dump="/var/lib/redis/dump.rdb"
        if [[ -f "$redis_dump" ]]; then
            cp "$redis_dump" "$db_backup_dir/redis_backup.rdb"
            success "Redis backup completed"
        fi
    fi
}

# Backup application files
backup_files() {
    local backup_path="$1"
    local files_backup_dir="$backup_path/files"
    mkdir -p "$files_backup_dir"
    
    info "Starting files backup..."
    
    # Application source code
    if [[ -d "$PROJECT_ROOT/src" ]]; then
        cp -r "$PROJECT_ROOT/src" "$files_backup_dir/"
    fi
    
    # Configuration files
    if [[ -d "$PROJECT_ROOT/config" ]]; then
        cp -r "$PROJECT_ROOT/config" "$files_backup_dir/"
    fi
    
    # Static files
    if [[ -d "$PROJECT_ROOT/public" ]]; then
        cp -r "$PROJECT_ROOT/public" "$files_backup_dir/"
    fi
    
    # Package files
    cp "$PROJECT_ROOT/package.json" "$files_backup_dir/" 2>/dev/null || true
    cp "$PROJECT_ROOT/package-lock.json" "$files_backup_dir/" 2>/dev/null || true
    cp "$PROJECT_ROOT/.env" "$files_backup_dir/" 2>/dev/null || true
    
    success "Files backup completed"
}

# Backup Docker volumes
backup_docker_volumes() {
    local backup_path="$1"
    local volumes_backup_dir="$backup_path/docker_volumes"
    mkdir -p "$volumes_backup_dir"
    
    info "Starting Docker volumes backup..."
    
    # Get list of volumes
    local volumes
    volumes=$(docker volume ls --format "{{.Name}}" | grep -E "panel-tk|postgres|redis" || true)
    
    for volume in $volumes; do
        info "Backing up volume: $volume"
        
        # Create temporary container to backup volume
        docker run --rm \
            -v "$volume:/data" \
            -v "$volumes_backup_dir:/backup" \
            alpine \
            tar czf "/backup/${volume}.tar.gz" -C /data . \
            2>/dev/null || warning "Failed to backup volume: $volume"
    done
    
    success "Docker volumes backup completed"
}

# Backup configuration files
backup_configs() {
    local backup_path="$1"
    local configs_backup_dir="$backup_path/configs"
    mkdir -p "$configs_backup_dir"
    
    info "Starting configuration backup..."
    
    # Docker configurations
    if [[ -d "$PROJECT_ROOT/docker" ]]; then
        cp -r "$PROJECT_ROOT/docker" "$configs_backup_dir/"
    fi
    
    # Nginx configurations
    if [[ -d "/etc/nginx/sites-available" ]]; then
        cp -r "/etc/nginx/sites-available" "$configs_backup_dir/nginx/"
    fi
    
    # System configurations
    cp /etc/hosts "$configs_backup_dir/" 2>/dev/null || true
    cp /etc/resolv.conf "$configs_backup_dir/" 2>/dev/null || true
    
    # Cron jobs
    crontab -l > "$configs_backup_dir/crontab.txt" 2>/dev/null || true
    
    success "Configuration backup completed"
}

# Backup logs
backup_logs() {
    local backup_path="$1"
    local logs_backup_dir="$backup_path/logs"
    mkdir -p "$logs_backup_dir"
    
    info "Starting logs backup..."
    
    # Application logs
    if [[ -d "/var/log/panel-tk" ]]; then
        cp -r "/var/log/panel-tk" "$logs_backup_dir/"
    fi
    
    # System logs (last 7 days)
    find /var/log -name "*.log" -mtime -7 -exec cp {} "$logs_backup_dir/system/" \; 2>/dev/null || true
    
    success "Logs backup completed"
}

# Compress backup
compress_backup() {
    local backup_path="$1"
    local backup_name=$(basename "$backup_path")
    local compressed_file="${backup_path}.tar.gz"
    
    info "Compressing backup..."
    
    tar -czf "$compressed_file" \
        -C "$(dirname "$backup_path")" \
        "$backup_name" \
        --exclude="*.tmp" \
        --exclude="*.log" \
        --exclude="*.pid"
    
    # Remove uncompressed directory
    rm -rf "$backup_path"
    
    success "Backup compressed: $compressed_file"
    
    echo "$compressed_file"
}

# Encrypt backup
encrypt_backup() {
    local backup_file="$1"
    
    if [[ "$ENCRYPT_BACKUP" == "true" ]]; then
        if [[ -f "$ENCRYPTION_KEY_FILE" ]]; then
            info "Encrypting backup..."
            
            local encrypted_file="${backup_file}.gpg"
            gpg --batch --yes --symmetric \
                --cipher-algo AES256 \
                --compress-algo 1 \
                --passphrase-file "$ENCRYPTION_KEY_FILE" \
                --output "$encrypted_file" \
                "$backup_file"
            
            rm "$backup_file"
            success "Backup encrypted: $encrypted_file"
            
            echo "$encrypted_file"
        else
            warning "Encryption key file not found, skipping encryption"
            echo "$backup_file"
        fi
    else
        echo "$backup_file"
    fi
}

# Upload to remote server
upload_remote() {
    local backup_file="$1"
    
    if [[ "$REMOTE_BACKUP" == "true" ]]; then
        if [[ -n "$REMOTE_HOST" && -n "$REMOTE_USER" && -n "$REMOTE_PATH" ]]; then
            info "Uploading to remote server..."
            
            scp "$backup_file" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/" \
                && success "Backup uploaded to remote server" \
                || error "Failed to upload to remote server"
        else
            warning "Remote backup enabled but configuration incomplete"
        fi
    fi
}

# Upload to S3
upload_s3() {
    local backup_file="$1"
    
    if [[ "$S3_BACKUP" == "true" ]]; then
        if command -v aws &> /dev/null && [[ -n "$S3_BUCKET" ]]; then
            info "Uploading to S3..."
            
            local backup_name=$(basename "$backup_file")
            aws s3 cp "$backup_file" "s3://${S3_BUCKET}/panel-tk-backups/${backup_name}" \
                --region "$S3_REGION" \
                && success "Backup uploaded to S3" \
                || error "Failed to upload to S3"
        else
            warning "AWS CLI not found or S3 bucket not configured"
        fi
    fi
}

# Clean old backups
clean_old_backups() {
    info "Cleaning old backups..."
    
    # Local backups
    find "$BACKUP_DIR" -name "*.tar.gz*" -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
    
    # Remote backups (if configured)
    if [[ "$REMOTE_BACKUP" == "true" ]]; then
        ssh "${REMOTE_USER}@${REMOTE_HOST}" \
            "find ${REMOTE_PATH} -name '*.tar.gz*' -mtime +${RETENTION_DAYS} -delete" \
            2>/dev/null || true
    fi
    
    # S3 backups
    if [[ "$S3_BACKUP" == "true" ]]; then
        aws s3 ls "s3://${S3_BUCKET}/panel-tk-backups/" \
            --region "$S3_REGION" \
            | awk '{print $4}' \
            | while read -r file; do
                local file_date=$(echo "$file" | grep -o '[0-9]\{8\}_[0-9]\{6\}')
                local file_age=$(( ($(date +%s) - $(date -d "${file_date:0:8} ${file_date:9:2}:${file_date:11:2}:${file_date:13:2}" +%s)) / 86400 ))
                
                if [[ $file_age -gt $RETENTION_DAYS ]]; then
                    aws s3 rm "s3://${S3_BUCKET}/panel-tk-backups/${file}" \
                        --region "$S3_REGION" \
                        2>/dev/null || true
                fi
            done
    fi
    
    success "Old backups cleaned"
}

# Verify backup integrity
verify_backup() {
    local backup_file="$1"
    
    info "Verifying backup integrity..."
    
    if [[ "$backup_file" == *.gpg ]]; then
        # Decrypt and verify
        local temp_file="${backup_file%.gpg}.tmp"
        gpg --batch --yes --decrypt \
            --passphrase-file "$ENCRYPTION_KEY_FILE" \
            --output "$temp_file" \
            "$backup_file" \
            2>/dev/null || {
                error "Backup verification failed (decryption)"
                return 1
            }
        
        if tar -tzf "$temp_file" >/dev/null 2>&1; then
            success "Backup verification successful"
            rm "$temp_file"
            return 0
        else
            error "Backup verification failed (corrupted archive)"
            rm "$temp_file"
            return 1
        fi
    else
        # Verify tar.gz
        if tar -tzf "$backup_file" >/dev/null 2>&1; then
            success "Backup verification successful"
            return 0
        else
            error "Backup verification failed (corrupted archive)"
            return 1
        fi
    fi
}

# Generate backup report
generate_report() {
    local backup_file="$1"
    local report_file="${backup_file}.report"
    
    info "Generating backup report..."
    
    cat > "$report_file" << EOF
PanelTK Backup Report
====================
Backup Date: $(date)
Backup File: $(basename "$backup_file")
Backup Size: $(du -h "$backup_file" | cut -f1)
Backup Type: $(if [[ "$backup_file" == *.gpg ]]; then echo "Encrypted"; else echo "Standard"; fi)
Components Backed Up:
$(if [[ "$BACKUP_DATABASE" == "true" ]]; then echo "- Database (PostgreSQL, Redis)"; fi)
$(if [[ "$BACKUP_FILES" == "true" ]]; then echo "- Application Files"; fi)
$(if [[ "$BACKUP_DOCKER_VOLUMES" == "true" ]]; then echo "- Docker Volumes"; fi)
$(if [[ "$BACKUP_CONFIGS" == "true" ]]; then echo "- Configuration Files"; fi)
$(if [[ "$BACKUP_LOGS" == "true" ]]; then echo "- Log Files"; fi)
Remote Backup: $REMOTE_BACKUP
S3 Backup: $S3_BACKUP
Retention Days: $RETENTION_DAYS
EOF
    
    success "Backup report generated: $report_file"
}

# Main backup function
perform_backup() {
    local backup_path=$(init_backup)
    
    log "Starting PanelTK backup..."
    
    # Perform backups based on configuration
    [[ "$BACKUP_DATABASE" == "true" ]] && backup_database "$backup_path"
    [[ "$BACKUP_FILES" == "true" ]] && backup_files "$backup_path"
    [[ "$BACKUP_DOCKER_VOLUMES" == "true" ]] && backup_docker_volumes "$backup_path"
    [[ "$BACKUP_CONFIGS" == "true" ]] && backup_configs "$backup_path"
    [[ "$BACKUP_LOGS" == "true" ]] && backup_logs "$backup_path"
    
    # Compress and encrypt
    local compressed_file=$(compress_backup "$backup_path")
    local final_file=$(encrypt_backup "$compressed_file")
    
    # Verify integrity
    verify_backup "$final_file"
    
    # Upload to remote locations
    upload_remote "$final_file"
    upload_s3 "$final_file"
    
    # Generate report
    generate_report "$final_file"
    
    # Clean old backups
    clean_old_backups
    
    success "Backup completed successfully: $final_file"
    
    # Cleanup
    rm -rf "$TEMP_DIR"
}

# Handle command line arguments
case "${1:-}" in
    --help|-h)
        echo "PanelTK Backup Script"
        echo ""
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --help, -h         Show this help message"
        echo "  --full             Perform full backup (default)"
        echo "  --database         Backup only database"
        echo "  --files            Backup only files"
        echo "  --volumes          Backup only Docker volumes"
        echo "  --configs          Backup only configurations"
        echo "  --logs             Backup only logs"
        echo "  --list             List available backups"
        echo "  --restore FILE     Restore from backup"
        echo "  --verify FILE      Verify backup integrity"
        echo "  --config FILE      Use custom config file"
        echo "  --clean            Clean old backups"
        echo ""
        exit 0
        ;;
    --full)
        perform_backup
        ;;
    --database)
        BACKUP_FILES=false
        BACKUP_DOCKER_VOLUMES=false
        BACKUP_CONFIGS=false
        BACKUP_LOGS=false
        perform_backup
        ;;
    --files)
        BACKUP_DATABASE=false
        BACKUP_DOCKER_VOLUMES=false
        BACKUP_CONFIGS=false
        BACKUP_LOGS=false
        perform_backup
        ;;
    --volumes)
        BACKUP_DATABASE=false
        BACKUP_FILES=false
        BACKUP_CONFIGS=false
        BACKUP_LOGS=false
        perform_backup
        ;;
    --configs)
        BACKUP_DATABASE=false
        BACKUP_FILES=false
        BACKUP_DOCKER_VOLUMES=false
        BACKUP_LOGS=false
        perform_backup
        ;;
    --logs)
        BACKUP_DATABASE=false
        BACKUP_FILES=false
        BACKUP_DOCKER_VOLUMES=false
        BACKUP_CONFIGS=false
        perform_backup
        ;;
    --list)
        echo "Available backups:"
        find "$BACKUP_DIR" -name "*.tar.gz*" -type f -printf "%T@ %Tc %p\n" | sort -nr | head -20 | while read -r timestamp date_str file; do
            local size=$(du -h "$file" | cut -f1)
            echo "  $date_str - $size - $(basename "$file")"
        done
        ;;
    --restore)
        if [[ -z "${2:-}" ]]; then
            error "Please specify backup file to restore"
            exit 1
        fi
        
        # Restore functionality would be implemented here
        info "Restore functionality not yet implemented"
        ;;
    --verify)
        if [[ -z "${2:-}" ]]; then
            error "Please specify backup file to verify"
            exit 1
        fi
        
        verify_backup "$2"
        ;;
    --clean)
        clean_old_backups
        ;;
    --config)
        CONFIG_FILE="${2:-$CONFIG_FILE}"
        shift 2
        perform_backup
        ;;
    *)
        perform_backup
        ;;
esac
