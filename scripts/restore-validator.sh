#!/bin/bash

# PanelTK Restore Validator
# Comprehensive validation suite for restore operations

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/app/config/restore-config.yml"
LOG_FILE="/app/logs/restore-validator.log"
VALIDATION_REPORT="/app/logs/validation-report.json"

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
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$VALIDATION_REPORT")"

# Validation results
declare -A validation_results
validation_count=0
validation_passed=0
validation_failed=0

# Function to load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Loading configuration from $CONFIG_FILE"
        
        # Load validation rules
        VALIDATE_DATABASE=$(yq eval '.validation.database.enabled // true' "$CONFIG_FILE")
        VALIDATE_FILES=$(yq eval '.validation.files.enabled // true' "$CONFIG_FILE")
        VALIDATE_SERVICES=$(yq eval '.validation.services.enabled // true' "$CONFIG_FILE")
        VALIDATE_INTEGRITY=$(yq eval '.validation.integrity.enabled // true' "$CONFIG_FILE")
        VALIDATE_PERFORMANCE=$(yq eval '.validation.performance.enabled // true' "$CONFIG_FILE")
        
        # Load thresholds
        MAX_RESPONSE_TIME=$(yq eval '.validation.performance.max_response_time // 5000' "$CONFIG_FILE")
        MIN_MEMORY_AVAILABLE=$(yq eval '.validation.performance.min_memory_available // 100' "$CONFIG_FILE")
        MIN_DISK_SPACE=$(yq eval '.validation.performance.min_disk_space // 1000' "$CONFIG_FILE")
    else
        warning "Configuration file not found, using defaults"
        VALIDATE_DATABASE=true
        VALIDATE_FILES=true
        VALIDATE_SERVICES=true
        VALIDATE_INTEGRITY=true
        VALIDATE_PERFORMANCE=true
        MAX_RESPONSE_TIME=5000
        MIN_MEMORY_AVAILABLE=100
        MIN_DISK_SPACE=1000
    fi
}

# Function to validate database
validate_database() {
    local test_name="database_validation"
    local status="PASSED"
    local details=""
    
    info "Validating database..."
    
    # Check PostgreSQL connection
    if docker-compose exec -T postgres pg_isready -U postgres >/dev/null 2>&1; then
        details+="PostgreSQL connection: OK\n"
        
        # Check database exists
        if docker-compose exec -T postgres psql -U postgres -d paneltk -c "\dt" >/dev/null 2>&1; then
            details+="Database 'paneltk' exists: OK\n"
            
            # Check tables
            local table_count=$(docker-compose exec -T postgres psql -U postgres -d paneltk -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" | tr -d '[:space:]')
            if [[ $table_count -gt 0 ]]; then
                details+="Tables found: $table_count: OK\n"
            else
                details+="No tables found: FAILED\n"
                status="FAILED"
            fi
        else
            details+="Database 'paneltk' does not exist: FAILED\n"
            status="FAILED"
        fi
    else
        details+="PostgreSQL connection failed: FAILED\n"
        status="FAILED"
    fi
    
    # Store result
    validation_results["$test_name"]="$status|$details"
    ((validation_count++))
    if [[ $status == "PASSED" ]]; then
        ((validation_passed++))
    else
        ((validation_failed++))
    fi
    
    log "Database validation: $status"
}

# Function to validate files
validate_files() {
    local test_name="files_validation"
    local status="PASSED"
    local details=""
    
    info "Validating files..."
    
    # Check critical directories
    local critical_dirs=("/app/uploads" "/app/logs" "/app/backups" "/app/config")
    
    for dir in "${critical_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            details+="Directory $dir: OK\n"
            
            # Check permissions
            if [[ -r "$dir" && -w "$dir" ]]; then
                details+="Permissions for $dir: OK\n"
            else
                details+="Permissions for $dir: FAILED\n"
                status="FAILED"
            fi
        else
            details+="Directory $dir: MISSING\n"
            status="FAILED"
        fi
    done
    
    # Check configuration files
    local config_files=("/app/config/database.yml" "/app/config/app.yml" "/app/config/restore-config.yml")
    
    for file in "${config_files[@]}"; do
        if [[ -f "$file" ]]; then
            details+="Config file $file: OK\n"
        else
            details+="Config file $file: MISSING\n"
            status="FAILED"
        fi
    done
    
    # Store result
    validation_results["$test_name"]="$status|$details"
    ((validation_count++))
    if [[ $status == "PASSED" ]]; then
        ((validation_passed++))
    else
        ((validation_failed++))
    fi
    
    log "Files validation: $status"
}

# Function to validate services
validate_services() {
    local test_name="services_validation"
    local status="PASSED"
    local details=""
    
    info "Validating services..."
    
    # Check Docker services
    local services=("postgres" "redis" "app" "nginx")
    
    for service in "${services[@]}"; do
        if docker-compose ps "$service" | grep -q "Up"; then
            details+="Service $service: RUNNING\n"
            
            # Check health if available
            if docker-compose ps "$service" | grep -q "healthy"; then
                details+="Service $service: HEALTHY\n"
            else
                details+="Service $service: HEALTH CHECK FAILED\n"
                status="FAILED"
            fi
        else
            details+="Service $service: NOT RUNNING\n"
            status="FAILED"
        fi
    done
    
    # Check port availability
    local ports=(3000 5432 6379 80 443)
    
    for port in "${ports[@]}"; do
        if netstat -tuln | grep -q ":$port "; then
            details+="Port $port: LISTENING\n"
        else
            details+="Port $port: NOT LISTENING\n"
            status="FAILED"
        fi
    done
    
    # Store result
    validation_results["$test_name"]="$status|$details"
    ((validation_count++))
    if [[ $status == "PASSED" ]]; then
        ((validation_passed++))
    else
        ((validation_failed++))
    fi
    
    log "Services validation: $status"
}

# Function to validate integrity
validate_integrity() {
    local test_name="integrity_validation"
    local status="PASSED"
    local details=""
    
    info "Validating data integrity..."
    
    # Check backup integrity
    local latest_backup=$(ls -t /app/backups/*.tar.gz 2>/dev/null | head -1)
    
    if [[ -n "$latest_backup" ]]; then
        details+="Latest backup: $latest_backup\n"
        
        if tar -tzf "$latest_backup" >/dev/null 2>&1; then
            details+="Backup integrity: OK\n"
        else
            details+="Backup integrity: CORRUPTED\n"
            status="FAILED"
        fi
    else
        details+="No backup found: WARNING\n"
        status="WARNING"
    fi
    
    # Check database integrity
    if [[ $VALIDATE_DATABASE == "true" ]]; then
        # Check for data corruption
        local corrupt_tables=$(docker-compose exec -T postgres psql -U postgres -d paneltk -t -c "SELECT schemaname, tablename FROM pg_tables WHERE schemaname='public' AND tablename NOT LIKE 'pg_%';" | tr -d '[:space:]')
        
        if [[ -n "$corrupt_tables" ]]; then
            details+="Database tables: OK\n"
        else
            details+="Database tables: EMPTY\n"
            status="FAILED"
        fi
    fi
    
    # Store result
    validation_results["$test_name"]="$status|$details"
    ((validation_count++))
    if [[ $status == "PASSED" ]]; then
        ((validation_passed++))
    else
        ((validation_failed++))
    fi
    
    log "Integrity validation: $status"
}

# Function to validate performance
validate_performance() {
    local test_name="performance_validation"
    local status="PASSED"
    local details=""
    
    info "Validating performance..."
    
    # Check response time
    local response_time=$(curl -o /dev/null -s -w '%{time_total}' http://localhost:3000/health || echo "9999")
    local response_ms=$(echo "$response_time * 1000" | bc -l | cut -d. -f1)
    
    if [[ $response_ms -lt $MAX_RESPONSE_TIME ]]; then
        details+="Response time: ${response_ms}ms: OK\n"
    else
        details+="Response time: ${response_ms}ms: FAILED (threshold: ${MAX_RESPONSE_TIME}ms)\n"
        status="FAILED"
    fi
    
    # Check memory usage
    local memory_available=$(free -m | awk 'NR==2{print $7}')
    if [[ $memory_available -gt $MIN_MEMORY_AVAILABLE ]]; then
        details+="Memory available: ${memory_available}MB: OK\n"
    else
        details+="Memory available: ${memory_available}MB: FAILED (threshold: ${MIN_MEMORY_AVAILABLE}MB)\n"
        status="FAILED"
    fi
    
    # Check disk space
    local disk_space=$(df /app | tail -1 | awk '{print $4}')
    if [[ $disk_space -gt $MIN_DISK_SPACE ]]; then
        details+="Disk space: ${disk_space}MB: OK\n"
    else
        details+="Disk space: ${disk_space}MB: FAILED (threshold: ${MIN_DISK_SPACE}MB)\n"
        status="FAILED"
    fi
    
    # Store result
    validation_results["$test_name"]="$status|$details"
    ((validation_count++))
    if [[ $status == "PASSED" ]]; then
        ((validation_passed++))
    else
        ((validation_failed++))
    fi
    
    log "Performance validation: $status"
}

# Function to run all validations
run_all_validations() {
    info "Starting comprehensive validation..."
    
    [[ $VALIDATE_DATABASE == "true" ]] && validate_database
    [[ $VALIDATE_FILES == "true" ]] && validate_files
    [[ $VALIDATE_SERVICES == "true" ]] && validate_services
    [[ $VALIDATE_INTEGRITY == "true" ]] && validate_integrity
    [[ $VALIDATE_PERFORMANCE == "true" ]] && validate_performance
    
    success "Validation completed"
}

# Function to generate validation report
generate_report() {
    local report_file="$1"
    
    info "Generating validation report..."
    
    # Create JSON report
    cat > "$report_file" <<EOF
{
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "summary": {
        "total_tests": $validation_count,
        "passed": $validation_passed,
        "failed": $validation_failed,
        "success_rate": $(echo "scale=2; $validation_passed * 100 / $validation_count" | bc -l)
    },
    "results": {
EOF
    
    local first=true
    for test in "${!validation_results[@]}"; do
        if [[ $first == true ]]; then
            first=false
        else
            echo "," >> "$report_file"
        fi
        
        local result="${validation_results[$test]}"
        local status="${result%%|*}"
        local details="${result#*|}"
        
        echo "        \"$test\": {" >> "$report_file"
        echo "            \"status\": \"$status\"," >> "$report_file"
        echo "            \"details\": \"$details\"" >> "$report_file"
        echo -n "        }" >> "$report_file"
    done
    
    cat >> "$report_file" <<EOF
    },
    "recommendations": [
        $(if [[ $validation_failed -gt 0 ]]; then
            echo "\"Address failed validations immediately\","
        fi)
        $(if [[ $validation_passed -lt $validation_count ]]; then
            echo "\"Review configuration and system resources\","
        fi)
        "Run validation again after fixes"
    ]
}
EOF
    
    success "Validation report generated: $report_file"
}

# Function to validate specific component
validate_component() {
    local component="$1"
    
    case "$component" in
        "database")
            validate_database
            ;;
        "files")
            validate_files
            ;;
        "services")
            validate_services
            ;;
        "integrity")
            validate_integrity
            ;;
        "performance")
            validate_performance
            ;;
        *)
            error "Unknown component: $component"
            return 1
            ;;
    esac
    
    generate_report "$VALIDATION_REPORT"
}

# Main function
main() {
    load_config
    
    case "${1:-}" in
        "all")
            run_all_validations
            generate_report "$VALIDATION_REPORT"
            ;;
        "component")
            validate_component "${2:-}"
            ;;
        "report")
            generate_report "${2:-$VALIDATION_REPORT}"
            ;;
        *)
            echo "Usage: $0 {all|component|report}"
            echo "  all              - Run all validations"
            echo "  component <name> - Validate specific component"
            echo "  report [file]    - Generate validation report"
            echo ""
            echo "Available components:"
            echo "  database, files, services, integrity, performance"
            exit 1
            ;;
    esac
    
    # Print summary
    echo ""
    echo "Validation Summary:"
    echo "=================="
    echo "Total tests: $validation_count"
    echo "Passed: $validation_passed"
    echo "Failed: $validation_failed"
    echo "Success rate: $(echo "scale=2; $validation_passed * 100 / $validation_count" | bc -l)%"
    
    if [[ $validation_failed -gt 0 ]]; then
        exit 1
    fi
}

# Handle command line arguments
main "$@"
