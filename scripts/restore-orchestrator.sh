#!/bin/bash

# PanelTK Restore Orchestrator
# Central orchestration script for complete restore operations

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/app/config/restore-config.yml"
LOG_FILE="/app/logs/restore-orchestrator.log"
ORCHESTRATION_LOG="/app/logs/orchestration.log"
BACKUP_DIR="/app/backups"
RESTORE_DIR="/app/restore"

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
mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR" "$RESTORE_DIR"

# Global variables
RESTORE_ID=""
BACKUP_FILE=""
RESTORE_MODE=""
START_TIME=""
END_TIME=""
ORCHESTRATION_STATUS="PENDING"

# Function to load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Loading configuration from $CONFIG_FILE"
        
        # Load orchestration settings
        PARALLEL_VALIDATION=$(yq eval '.orchestration.parallel_validation // true' "$CONFIG_FILE")
        ROLLBACK_ON_FAILURE=$(yq eval '.orchestration.rollback_on_failure // true' "$CONFIG_FILE")
        NOTIFICATION_ENABLED=$(yq eval '.orchestration.notifications.enabled // false' "$CONFIG_FILE")
        HEALTH_CHECK_INTERVAL=$(yq eval '.orchestration.health_check_interval // 30' "$CONFIG_FILE")
        
        # Load restore settings
        RESTORE_TIMEOUT=$(yq eval '.restore.timeout // 3600' "$CONFIG_FILE")
        VALIDATION_TIMEOUT=$(yq eval '.validation.timeout // 600' "$CONFIG_FILE")
    else
        warning "Configuration file not found, using defaults"
        PARALLEL_VALIDATION=true
        ROLLBACK_ON_FAILURE=true
        NOTIFICATION_ENABLED=false
        HEALTH_CHECK_INTERVAL=30
        RESTORE_TIMEOUT=3600
        VALIDATION_TIMEOUT=600
    fi
}

# Function to generate restore ID
generate_restore_id() {
    RESTORE_ID="restore-$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 4)"
    log "Generated restore ID: $RESTORE_ID"
}

# Function to initialize orchestration
init_orchestration() {
    START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    ORCHESTRATION_STATUS="INITIALIZING"
    
    log "Initializing restore orchestration"
    log "Restore ID: $RESTORE_ID"
    log "Start time: $START_TIME"
    
    # Create orchestration directory
    mkdir -p "$RESTORE_DIR/$RESTORE_ID"
    
    # Initialize orchestration log
    cat > "$RESTORE_DIR/$RESTORE_ID/orchestration.json" <<EOF
{
    "restore_id": "$RESTORE_ID",
    "start_time": "$START_TIME",
    "status": "$ORCHESTRATION_STATUS",
    "backup_file": "$BACKUP_FILE",
    "restore_mode": "$RESTORE_MODE",
    "steps": []
}
EOF
}

# Function to update orchestration status
update_status() {
    local step="$1"
    local status="$2"
    local details="${3:-}"
    
    ORCHESTRATION_STATUS="$status"
    
    # Update orchestration log
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    # Add step to orchestration log
    local step_json=$(cat <<EOF
{
    "step": "$step",
    "status": "$status",
    "timestamp": "$timestamp",
    "details": "$details"
}
EOF
)
    
    # Update JSON file
    local temp_file=$(mktemp)
    jq --argjson step "$step_json" '.steps += [$step] | .status = $step.status' \
        "$RESTORE_DIR/$RESTORE_ID/orchestration.json" > "$temp_file" && \
        mv "$temp_file" "$RESTORE_DIR/$RESTORE_ID/orchestration.json"
    
    log "Step '$step' status: $status"
    [[ -n "$details" ]] && log "Details: $details"
}

# Function to pre-flight checks
preflight_checks() {
    update_status "preflight_checks" "RUNNING"
    
    log "Running pre-flight checks..."
    
    # Check if Docker is running
    if ! docker info >/dev/null 2>&1; then
        update_status "preflight_checks" "FAILED" "Docker is not running"
        return 1
    fi
    
    # Check if backup file exists
    if [[ ! -f "$BACKUP_FILE" ]]; then
        update_status "preflight_checks" "FAILED" "Backup file not found: $BACKUP_FILE"
        return 1
    fi
    
    # Validate backup file
    if ! "$SCRIPT_DIR/validate-backup.sh" "$BACKUP_FILE"; then
        update_status "preflight_checks" "FAILED" "Backup validation failed"
        return 1
    fi
    
    # Check disk space
    local required_space=$(du -m "$BACKUP_FILE" | cut -f1)
    local available_space=$(df /app | tail -1 | awk '{print $4}')
    
    if [[ $available_space -lt $((required_space * 2)) ]]; then
        update_status "preflight_checks" "FAILED" "Insufficient disk space"
        return 1
    fi
    
    update_status "preflight_checks" "COMPLETED"
    return 0
}

# Function to prepare environment
prepare_environment() {
    update_status "prepare_environment" "RUNNING"
    
    log "Preparing environment for restore..."
    
    # Stop services
    log "Stopping services..."
    docker-compose down
    
    # Clean up old data
    log "Cleaning up old data..."
    docker volume prune -f
    
    # Create restore directories
    mkdir -p "$RESTORE_DIR/$RESTORE_ID/data"
    mkdir -p "$RESTORE_DIR/$RESTORE_ID/logs"
    
    update_status "prepare_environment" "COMPLETED"
}

# Function to execute restore
execute_restore() {
    update_status "execute_restore" "RUNNING"
    
    log "Executing restore operation..."
    
    # Run restore with timeout
    timeout "$RESTORE_TIMEOUT" "$SCRIPT_DIR/restore.sh" "$BACKUP_FILE" "$RESTORE_MODE" || {
        update_status "execute_restore" "FAILED" "Restore operation timed out or failed"
        return 1
    }
    
    update_status "execute_restore" "COMPLETED"
}

# Function to validate restore
validate_restore() {
    update_status "validate_restore" "RUNNING"
    
    log "Validating restore operation..."
    
    # Run validation with timeout
    timeout "$VALIDATION_TIMEOUT" "$SCRIPT_DIR/restore-validator.sh" all || {
        update_status "validate_restore" "FAILED" "Validation failed"
        return 1
    }
    
    update_status "validate_restore" "COMPLETED"
}

# Function to health check
health_check() {
    update_status "health_check" "RUNNING"
    
    log "Performing health checks..."
    
    # Start services
    docker-compose up -d
    
    # Wait for services to be ready
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if "$SCRIPT_DIR/health-check.sh"; then
            update_status "health_check" "COMPLETED"
            return 0
        fi
        
        ((attempt++))
        log "Health check attempt $attempt/$max_attempts failed, retrying..."
        sleep "$HEALTH_CHECK_INTERVAL"
    done
    
    update_status "health_check" "FAILED" "Health checks failed after $max_attempts attempts"
    return 1
}

# Function to rollback on failure
rollback_restore() {
    update_status "rollback" "RUNNING"
    
    log "Rolling back restore operation..."
    
    # Stop services
    docker-compose down
    
    # Restore from backup
    if [[ -f "$RESTORE_DIR/$RESTORE_ID/pre-restore-backup.tar.gz" ]]; then
        log "Restoring from pre-restore backup..."
        "$SCRIPT_DIR/restore.sh" "$RESTORE_DIR/$RESTORE_ID/pre-restore-backup.tar.gz" "full"
    fi
    
    # Start services
    docker-compose up -d
    
    update_status "rollback" "COMPLETED"
}

# Function to cleanup
cleanup() {
    update_status "cleanup" "RUNNING"
    
    log "Cleaning up temporary files..."
    
    # Remove temporary files
    rm -rf "$RESTORE_DIR/$RESTORE_ID/temp"
    
    # Archive logs
    if [[ -d "$RESTORE_DIR/$RESTORE_ID" ]]; then
        tar -czf "$RESTORE_DIR/$RESTORE_ID/logs.tar.gz" -C "$RESTORE_DIR/$RESTORE_ID" logs/
    fi
    
    update_status "cleanup" "COMPLETED"
}

# Function to send notifications
send_notifications() {
    if [[ $NOTIFICATION_ENABLED == "true" ]]; then
        log "Sending notifications..."
        
        # Send email notification
        local subject="Restore Operation $ORCHESTRATION_STATUS - $RESTORE_ID"
        local body="Restore operation completed with status: $ORCHESTRATION_STATUS"
        
        # Add notification logic here based on configuration
        log "Notification sent: $subject"
    fi
}

# Function to generate final report
generate_final_report() {
    END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    log "Generating final report..."
    
    # Calculate duration
    local start_epoch=$(date -d "$START_TIME" +%s)
    local end_epoch=$(date -d "$END_TIME" +%s)
    local duration=$((end_epoch - start_epoch))
    
    # Create final report
    cat > "$RESTORE_DIR/$RESTORE_ID/final-report.json" <<EOF
{
    "restore_id": "$RESTORE_ID",
    "start_time": "$START_TIME",
    "end_time": "$END_TIME",
    "duration_seconds": $duration,
    "status": "$ORCHESTRATION_STATUS",
    "backup_file": "$BACKUP_FILE",
    "restore_mode": "$RESTORE_MODE",
    "summary": {
        "total_steps": $(jq '.steps | length' "$RESTORE_DIR/$RESTORE_ID/orchestration.json"),
        "successful_steps": $(jq '[.steps[] | select(.status == "COMPLETED")] | length' "$RESTORE_DIR/$RESTORE_ID/orchestration.json"),
        "failed_steps": $(jq '[.steps[] | select(.status == "FAILED")] | length' "$RESTORE_DIR/$RESTORE_ID/orchestration.json")
    },
    "logs": {
        "orchestration_log": "$RESTORE_DIR/$RESTORE_ID/orchestration.json",
        "system_log": "$LOG_FILE"
    }
}
EOF
    
    log "Final report generated: $RESTORE_DIR/$RESTORE_ID/final-report.json"
}

# Function to run full orchestration
run_orchestration() {
    log "Starting restore orchestration..."
    
    # Initialize
    init_orchestration
    
    # Pre-flight checks
    if ! preflight_checks; then
        ORCHESTRATION_STATUS="FAILED"
        generate_final_report
        return 1
    fi
    
    # Prepare environment
    if ! prepare_environment; then
        ORCHESTRATION_STATUS="FAILED"
        generate_final_report
        return 1
    fi
    
    # Create pre-restore backup
    log "Creating pre-restore backup..."
    docker-compose exec -T app tar -czf "$RESTORE_DIR/$RESTORE_ID/pre-restore-backup.tar.gz" -C /app .
    
    # Execute restore
    if ! execute_restore; then
        ORCHESTRATION_STATUS="FAILED"
        if [[ $ROLLBACK_ON_FAILURE == "true" ]]; then
            rollback_restore
        fi
        generate_final_report
        return 1
    fi
    
    # Validate restore
    if ! validate_restore; then
        ORCHESTRATION_STATUS="FAILED"
        if [[ $ROLLBACK_ON_FAILURE == "true" ]]; then
            rollback_restore
        fi
        generate_final_report
        return 1
    fi
    
    # Health check
    if ! health_check; then
        ORCHESTRATION_STATUS="FAILED"
        if [[ $ROLLBACK_ON_FAILURE == "true" ]]; then
            rollback_restore
        fi
        generate_final_report
        return 1
    fi
    
    # Cleanup
    cleanup
    
    # Success
    ORCHESTRATION_STATUS="COMPLETED"
    generate_final_report
    send_notifications
    
    log "Restore orchestration completed successfully"
    return 0
}

# Function to show orchestration status
show_status() {
    local restore_id="${1:-}"
    
    if [[ -z "$restore_id" ]]; then
        # List all restore operations
        echo "Recent restore operations:"
        echo "========================="
        for dir in "$RESTORE_DIR"/restore-*; do
            if [[ -d "$dir" ]]; then
                local id=$(basename "$dir")
                local status=$(jq -r '.status' "$dir/orchestration.json" 2>/dev/null || echo "UNKNOWN")
                local start_time=$(jq -r '.start_time' "$dir/orchestration.json" 2>/dev/null || echo "UNKNOWN")
                printf "%-25s %-15s %s\n" "$id" "$status" "$start_time"
            fi
        done
    else
        # Show specific restore operation
        local report_file="$RESTORE_DIR/$restore_id/final-report.json"
        if [[ -f "$report_file" ]]; then
            echo "Restore Operation Details:"
            echo "========================="
            cat "$report_file" | jq .
        else
            echo "Restore operation not found: $restore_id"
        fi
    fi
}

# Main function
main() {
    load_config
    
    case "${1:-}" in
        "run")
            BACKUP_FILE="${2:-}"
            RESTORE_MODE="${3:-full}"
            
            if [[ -z "$BACKUP_FILE" ]]; then
                echo "Usage: $0 run <backup_file> [restore_mode]"
                echo "  backup_file: Path to backup file"
                echo "  restore_mode: full|partial|config (default: full)"
                exit 1
            fi
            
            generate_restore_id
            run_orchestration
            ;;
        "status")
            show_status "${2:-}"
            ;;
        "rollback")
            RESTORE_ID="${2:-}"
            if [[ -z "$RESTORE_ID" ]]; then
                echo "Usage: $0 rollback <restore_id>"
                exit 1
            fi
            
            ORCHESTRATION_STATUS="ROLLING_BACK"
            rollback_restore
            ;;
        *)
            echo "PanelTK Restore Orchestrator"
            echo "============================"
            echo ""
            echo "Usage: $0 {run|status|rollback}"
            echo ""
            echo "Commands:"
            echo "  run <backup_file> [mode]  - Run complete restore orchestration"
            echo "  status [restore_id]       - Show restore operation status"
            echo "  rollback <restore_id>     - Rollback specific restore operation"
            echo ""
            echo "Examples:"
            echo "  $0 run /app/backups/backup-20240101.tar.gz full"
            echo "  $0 status"
            echo "  $0 status restore-20240101-120000-abcd1234"
            echo "  $0 rollback restore-20240101-120000-abcd1234"
            exit 1
            ;;
    esac
}

# Handle command line arguments
main "$@"
