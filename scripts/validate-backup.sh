#!/bin/bash

# PanelTK Backup Validation Script
# This script validates backup integrity and completeness

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/app/config/restore-config.yml"
LOG_FILE="/app/logs/backup-validation.log"
BACKUP_DIR="/app/backups"
TEMP_DIR="/tmp/backup-validation"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Create temp directory
mkdir -p "$TEMP_DIR"

# Function to check if backup exists
check_backup_exists() {
    local backup_path="$1"
    if [[ ! -f "$backup_path" ]]; then
        error "Backup file not found: $backup_path"
    fi
}

# Function to validate backup structure
validate_backup_structure() {
    local backup_file="$1"
    local temp_extract="$TEMP_DIR/extracted"
    
    log "Validating backup structure..."
    
    mkdir -p "$temp_extract"
    
    # Extract backup
    if [[ "$backup_file" == *.tar.gz ]]; then
        tar -tzf "$backup_file" > "$temp_extract/file_list.txt" || error "Failed to list backup contents"
    elif [[ "$backup_file" == *.zip ]]; then
        unzip -l "$backup_file" > "$temp_extract/file_list.txt" || error "Failed to list backup contents"
    else
        error "Unsupported backup format: $backup_file"
    fi
    
    # Check required files
    local required_files=(
        "database/postgres_backup.sql"
        "volumes/postgres_data.tar.gz"
        "volumes/redis_data.tar.gz"
        "volumes/uploads.tar.gz"
        "config/app_config.json"
        "manifest.json"
    )
    
    for file in "${required_files[@]}"; do
        if ! grep -q "$file" "$temp_extract/file_list.txt"; then
            warning "Required file missing: $file"
        else
            success "Found required file: $file"
        fi
    done
    
    # Validate manifest
    if [[ -f "$temp_extract/manifest.json" ]]; then
        if jq empty "$temp_extract/manifest.json" 2>/dev/null; then
            success "Manifest file is valid JSON"
        else
            error "Invalid manifest file"
        fi
    fi
}

# Function to validate checksums
validate_checksums() {
    local backup_file="$1"
    local temp_extract="$TEMP_DIR/extracted"
    
    log "Validating checksums..."
    
    if [[ -f "$temp_extract/checksums.md5" ]]; then
        cd "$temp_extract"
        if md5sum -c checksums.md5 > /dev/null 2>&1; then
            success "All checksums are valid"
        else
            error "Checksum validation failed"
        fi
    else
        warning "No checksum file found"
    fi
}

# Function to validate database backup
validate_database_backup() {
    local backup_file="$1"
    local temp_extract="$TEMP_DIR/extracted"
    
    log "Validating database backup..."
    
    if [[ -f "$temp_extract/database/postgres_backup.sql" ]]; then
        # Check if it's a valid PostgreSQL dump
        if head -n 1 "$temp_extract/database/postgres_backup.sql" | grep -q "PostgreSQL database dump"; then
            success "Database backup appears to be valid PostgreSQL dump"
        else
            warning "Database backup may not be a valid PostgreSQL dump"
        fi
        
        # Check file size
        local size=$(stat -c%s "$temp_extract/database/postgres_backup.sql")
        if [[ $size -gt 1000 ]]; then
            success "Database backup has reasonable size: $size bytes"
        else
            error "Database backup appears to be too small: $size bytes"
        fi
    else
        error "Database backup file not found"
    fi
}

# Function to validate volume backups
validate_volume_backups() {
    local backup_file="$1"
    local temp_extract="$TEMP_DIR/extracted"
    
    log "Validating volume backups..."
    
    local volumes=("postgres_data" "redis_data" "uploads")
    
    for volume in "${volumes[@]}"; do
        local volume_file="$temp_extract/volumes/${volume}.tar.gz"
        if [[ -f "$volume_file" ]]; then
            # Check if it's a valid tar.gz
            if tar -tzf "$volume_file" > /dev/null 2>&1; then
                success "Volume backup is valid: $volume"
                
                # Check file size
                local size=$(stat -c%s "$volume_file")
                if [[ $size -gt 100 ]]; then
                    success "Volume backup has reasonable size: $volume ($size bytes)"
                else
                    warning "Volume backup appears small: $volume ($size bytes)"
                fi
            else
                error "Invalid volume backup: $volume"
            fi
        else
            warning "Volume backup not found: $volume"
        fi
    done
}

# Function to validate encryption
validate_encryption() {
    local backup_file="$1"
    
    log "Checking encryption status..."
    
    # Check if file is encrypted (basic check)
    if file "$backup_file" | grep -q "encrypted"; then
        success "Backup appears to be encrypted"
        
        # Check if encryption key is available
        if [[ -z "${ENCRYPTION_KEY:-}" ]]; then
            error "Encrypted backup found but no ENCRYPTION_KEY provided"
        else
            success "Encryption key is available"
        fi
    else
        success "Backup is not encrypted"
    fi
}

# Function to check backup age
check_backup_age() {
    local backup_file="$1"
    
    log "Checking backup age..."
    
    local backup_date=$(stat -c %Y "$backup_file")
    local current_date=$(date +%s)
    local age_days=$(( (current_date - backup_date) / 86400 ))
    
    if [[ $age_days -gt 30 ]]; then
        warning "Backup is $age_days days old (older than 30 days)"
    else
        success "Backup is recent: $age_days days old"
    fi
}

# Function to validate configuration
validate_configuration() {
    local backup_file="$1"
    local temp_extract="$TEMP_DIR/extracted"
    
    log "Validating configuration..."
    
    if [[ -f "$temp_extract/config/app_config.json" ]]; then
        if jq empty "$temp_extract/config/app_config.json" 2>/dev/null; then
            success "Configuration file is valid JSON"
        else
            error "Invalid configuration file"
        fi
    else
        warning "Configuration file not found"
    fi
}

# Main validation function
main() {
    log "Starting backup validation..."
    
    # Find latest backup
    local latest_backup=$(find "$BACKUP_DIR" -name "*.tar.gz" -o -name "*.zip" | sort -r | head -n1)
    
    if [[ -z "$latest_backup" ]]; then
        error "No backup files found in $BACKUP_DIR"
    fi
    
    log "Validating backup: $latest_backup"
    
    # Run validation checks
    check_backup_exists "$latest_backup"
    validate_backup_structure "$latest_backup"
    validate_checksums "$latest_backup"
    validate_database_backup "$latest_backup"
    validate_volume_backups "$latest_backup"
    validate_encryption "$latest_backup"
    check_backup_age "$latest_backup"
    validate_configuration "$latest_backup"
    
    # Generate validation report
    local report_file="/app/logs/validation-report-$(date +%Y%m%d_%H%M%S).json"
    cat > "$report_file" << EOF
{
    "backup_file": "$latest_backup",
    "validation_date": "$(date -Iseconds)",
    "status": "success",
    "checks_performed": [
        "backup_exists",
        "backup_structure",
        "checksums",
        "database_backup",
        "volume_backups",
        "encryption",
        "backup_age",
        "configuration"
    ],
    "backup_size": $(stat -c%s "$latest_backup"),
    "backup_age_days": $(( ($(date +%s) - $(stat -c %Y "$latest_backup")) / 86400 ))
}
EOF
    
    success "Backup validation completed successfully"
    log "Validation report saved to: $report_file"
    
    # Cleanup
    rm -rf "$TEMP_DIR"
}

# Execute main function
main "$@"
