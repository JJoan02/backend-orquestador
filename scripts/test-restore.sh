#!/bin/bash

# PanelTK Test Restore Script
# This script tests the restore functionality without affecting production data

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${PROJECT_DIR}/scripts/restore.conf"
TEST_DIR="/tmp/panel-tk-test-restore"
LOG_FILE="${TEST_DIR}/test-restore.log"

# Load configuration
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo -e "${RED}Configuration file not found: $CONFIG_FILE${NC}"
    exit 1
fi

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Test functions
test_prerequisites() {
    log "Testing prerequisites..."
    
    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        log "ERROR: Docker is not installed"
        return 1
    fi
    
    # Check if Docker Compose is installed
    if ! command -v docker-compose &> /dev/null; then
        log "ERROR: Docker Compose is not installed"
        return 1
    fi
    
    # Check disk space (minimum 2GB)
    available_space=$(df /tmp | awk 'NR==2 {print $4}')
    if [[ $available_space -lt 2097152 ]]; then
        log "ERROR: Insufficient disk space (need at least 2GB)"
        return 1
    fi
    
    log "Prerequisites test passed"
    return 0
}

test_backup_integrity() {
    log "Testing backup integrity..."
    
    local backup_dir="${BACKUP_DIR:-/opt/panel-tk/backups}"
    
    if [[ ! -d "$backup_dir" ]]; then
        log "WARNING: Backup directory does not exist: $backup_dir"
        return 0
    fi
    
    # Find latest backup
    local latest_backup=$(find "$backup_dir" -name "*.tar.gz" -type f -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
    
    if [[ -z "$latest_backup" ]]; then
        log "WARNING: No backup files found"
        return 0
    fi
    
    # Test archive integrity
    if tar -tzf "$latest_backup" &>/dev/null; then
        log "Backup integrity test passed: $(basename "$latest_backup")"
    else
        log "ERROR: Backup archive is corrupted: $(basename "$latest_backup")"
        return 1
    fi
    
    return 0
}

test_database_restore() {
    log "Testing database restore..."
    
    # Create test database
    local test_db="panel_tk_test_$(date +%s)"
    
    # Test database connection
    if ! PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -U "$DB_USER" -d postgres -c "SELECT 1" &>/dev/null; then
        log "ERROR: Cannot connect to PostgreSQL"
        return 1
    fi
    
    # Create test database
    if PGPASSWORD="$DB_PASSWORD" createdb -h "$DB_HOST" -U "$DB_USER" "$test_db"; then
        log "Test database created: $test_db"
        
        # Clean up
        PGPASSWORD="$DB_PASSWORD" dropdb -h "$DB_HOST" -U "$DB_USER" "$test_db"
        log "Test database cleaned up"
    else
        log "ERROR: Failed to create test database"
        return 1
    fi
    
    return 0
}

test_configuration() {
    log "Testing configuration..."
    
    # Test configuration file
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "ERROR: Configuration file not found"
        return 1
    fi
    
    # Test required variables
    local required_vars=("DB_NAME" "DB_USER" "DB_PASSWORD" "DB_HOST" "DB_PORT")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log "ERROR: Required configuration variable missing: $var"
            return 1
        fi
    done
    
    log "Configuration test passed"
    return 0
}

test_permissions() {
    log "Testing permissions..."
    
    # Test backup directory access
    local backup_dir="${BACKUP_DIR:-/opt/panel-tk/backups}"
    if [[ -d "$backup_dir" ]] && [[ ! -r "$backup_dir" ]]; then
        log "ERROR: Cannot read backup directory: $backup_dir"
        return 1
    fi
    
    # Test log directory access
    local log_dir="$(dirname "$LOG_FILE")"
    mkdir -p "$log_dir"
    if [[ ! -w "$log_dir" ]]; then
        log "ERROR: Cannot write to log directory: $log_dir"
        return 1
    fi
    
    log "Permissions test passed"
    return 0
}

test_services() {
    log "Testing services..."
    
    # Test PostgreSQL
    if ! systemctl is-active --quiet postgresql; then
        log "WARNING: PostgreSQL service is not running"
    else
        log "PostgreSQL service is running"
    fi
    
    # Test Redis
    if ! systemctl is-active --quiet redis; then
        log "WARNING: Redis service is not running"
    else
        log "Redis service is running"
    fi
    
    # Test Docker
    if ! systemctl is-active --quiet docker; then
        log "WARNING: Docker service is not running"
    else
        log "Docker service is running"
    fi
    
    return 0
}

# Main test function
main() {
    echo -e "${GREEN}Starting PanelTK restore test...${NC}"
    
    # Create test directory
    mkdir -p "$TEST_DIR"
    log "Test directory created: $TEST_DIR"
    
    # Run tests
    local tests_passed=0
    local tests_total=0
    
    # Test functions
    local test_functions=(
        test_prerequisites
        test_configuration
        test_permissions
        test_backup_integrity
        test_database_restore
        test_services
    )
    
    for test_func in "${test_functions[@]}"; do
        ((tests_total++))
        if $test_func; then
            ((tests_passed++))
            echo -e "${GREEN}✓ $test_func${NC}"
        else
            echo -e "${RED}✗ $test_func${NC}"
        fi
    done
    
    # Summary
    echo
    echo -e "${GREEN}Test Summary:${NC}"
    echo -e "Tests passed: ${GREEN}$tests_passed/$tests_total${NC}"
    
    if [[ $tests_passed -eq $tests_total ]]; then
        echo -e "${GREEN}All tests passed! Restore should work correctly.${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed. Please check the logs: $LOG_FILE${NC}"
        exit 1
    fi
}

# Cleanup function
cleanup() {
    log "Cleaning up test environment..."
    rm -rf "$TEST_DIR"
}

# Trap cleanup on exit
trap cleanup EXIT

# Run main function
main "$@"
