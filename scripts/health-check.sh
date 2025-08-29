#!/bin/bash
# PanelTK Health Check Script
# Comprehensive health monitoring for all PanelTK components

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_FILE="/var/log/panel-tk/health-check.log"
ALERT_FILE="/var/log/panel-tk/alerts.log"
CONFIG_FILE="/opt/panel-tk/config/health-check.conf"
WEBHOOK_URL=""  # Set via environment or config
SLACK_WEBHOOK=""  # Set via environment or config
DISCORD_WEBHOOK=""  # Set via environment or config

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Health check results
declare -A RESULTS
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNINGS=0

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$ALERT_FILE"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1" >> "$ALERT_FILE"
    ((WARNINGS++))
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
    [[ -n "${WEBHOOK_URL:-}" ]] && WEBHOOK_URL="$WEBHOOK_URL"
    [[ -n "${SLACK_WEBHOOK:-}" ]] && SLACK_WEBHOOK="$SLACK_WEBHOOK"
    [[ -n "${DISCORD_WEBHOOK:-}" ]] && DISCORD_WEBHOOK="$DISCORD_WEBHOOK"
}

# Send alert notification
send_alert() {
    local severity=$1
    local message=$2
    local component=$3
    
    # Log to file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $severity: $component - $message" >> "$ALERT_FILE"
    
    # Send webhook notification
    if [[ -n "$WEBHOOK_URL" ]]; then
        curl -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"severity\":\"$severity\",\"component\":\"$component\",\"message\":\"$message\",\"timestamp\":\"$(date -Iseconds)\"}" \
            >/dev/null 2>&1 || true
    fi
    
    # Send Slack notification
    if [[ -n "$SLACK_WEBHOOK" ]]; then
        curl -X POST "$SLACK_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"[$severity] $component: $message\"}" \
            >/dev/null 2>&1 || true
    fi
    
    # Send Discord notification
    if [[ -n "$DISCORD_WEBHOOK" ]]; then
        curl -X POST "$DISCORD_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"content\":\"[$severity] $component: $message\"}" \
            >/dev/null 2>&1 || true
    fi
}

# Check service status
check_service() {
    local service=$1
    local container_name=$2
    
    ((TOTAL_CHECKS++))
    
    if docker-compose ps | grep -q "$container_name.*Up"; then
        success "Service $service is running"
        RESULTS["$service"]="PASS"
        ((PASSED_CHECKS++))
        return 0
    else
        error "Service $service is not running"
        RESULTS["$service"]="FAIL"
        ((FAILED_CHECKS++))
        send_alert "CRITICAL" "Service $service is down" "docker"
        return 1
    fi
}

# Check HTTP endpoint
check_http_endpoint() {
    local name=$1
    local url=$2
    local expected_status=${3:-200}
    local timeout=${4:-10}
    
    ((TOTAL_CHECKS++))
    
    local response
    local status_code
    
    response=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$timeout" "$url" 2>/dev/null || echo "000")
    status_code=${response:0:3}
    
    if [[ "$status_code" == "$expected_status" ]]; then
        success "HTTP endpoint $name is responding ($status_code)"
        RESULTS["$name"]="PASS"
        ((PASSED_CHECKS++))
        return 0
    else
        error "HTTP endpoint $name is not responding correctly (got $status_code, expected $expected_status)"
        RESULTS["$name"]="FAIL"
        ((FAILED_CHECKS++))
        send_alert "CRITICAL" "HTTP endpoint $name returned $status_code" "http"
        return 1
    fi
}

# Check database connectivity
check_database() {
    ((TOTAL_CHECKS++))
    
    local db_host="${DB_HOST:-localhost}"
    local db_port="${DB_PORT:-5432}"
    local db_name="${DB_NAME:-panel_tk}"
    local db_user="${DB_USER:-paneltk}"
    local db_pass="${DB_PASSWORD:-}"
    
    if PGPASSWORD="$db_pass" pg_isready -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" -t 10 >/dev/null 2>&1; then
        success "Database is accessible"
        RESULTS["database"]="PASS"
        ((PASSED_CHECKS++))
        
        # Check database size
        local db_size
        db_size=$(PGPASSWORD="$db_pass" psql -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" -t -c "SELECT pg_size_pretty(pg_database_size('$db_name'));" 2>/dev/null | xargs)
        info "Database size: $db_size"
        
        return 0
    else
        error "Database is not accessible"
        RESULTS["database"]="FAIL"
        ((FAILED_CHECKS++))
        send_alert "CRITICAL" "Database connection failed" "database"
        return 1
    fi
}

# Check Redis connectivity
check_redis() {
    ((TOTAL_CHECKS++))
    
    local redis_host="${REDIS_HOST:-localhost}"
    local redis_port="${REDIS_PORT:-6379}"
    local redis_pass="${REDIS_PASSWORD:-}"
    
    local redis_cmd="redis-cli -h $redis_host -p $redis_port"
    [[ -n "$redis_pass" ]] && redis_cmd="$redis_cmd -a $redis_pass"
    
    if $redis_cmd ping >/dev/null 2>&1; then
        success "Redis is accessible"
        RESULTS["redis"]="PASS"
        ((PASSED_CHECKS++))
        
        # Check Redis memory usage
        local memory_usage
        memory_usage=$($redis_cmd info memory | grep used_memory_human | cut -d: -f2 | tr -d '\r')
        info "Redis memory usage: $memory_usage"
        
        return 0
    else
        error "Redis is not accessible"
        RESULTS["redis"]="FAIL"
        ((FAILED_CHECKS++))
        send_alert "CRITICAL" "Redis connection failed" "redis"
        return 1
    fi
}

# Check disk space
check_disk_space() {
    ((TOTAL_CHECKS++))
    
    local threshold=80
    local usage
    
    usage=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
    
    if [[ $usage -lt $threshold ]]; then
        success "Disk space usage is normal ($usage%)"
        RESULTS["disk_space"]="PASS"
        ((PASSED_CHECKS++))
        return 0
    else
        warning "Disk space usage is high ($usage%)"
        RESULTS["disk_space"]="WARN"
        ((WARNINGS++))
        send_alert "WARNING" "Disk space usage is ${usage}%" "disk"
        return 1
    fi
}

# Check memory usage
check_memory() {
    ((TOTAL_CHECKS++))
    
    local threshold=80
    local usage
    
    usage=$(free | awk 'NR==2{printf "%.0f", $3*100/$2}')
    
    if [[ $usage -lt $threshold ]]; then
        success "Memory usage is normal ($usage%)"
        RESULTS["memory"]="PASS"
        ((PASSED_CHECKS++))
        return 0
    else
        warning "Memory usage is high ($usage%)"
        RESULTS["memory"]="WARN"
        ((WARNINGS++))
        send_alert "WARNING" "Memory usage is ${usage}%" "memory"
        return 1
    fi
}

# Check CPU load
check_cpu_load() {
    ((TOTAL_CHECKS++))
    
    local threshold=80
    local load
    
    load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    local cpu_cores=$(nproc)
    local load_percent=$(echo "$load $cpu_cores" | awk '{printf "%.0f", ($1/$2)*100}')
    
    if [[ $load_percent -lt $threshold ]]; then
        success "CPU load is normal ($load_percent%)"
        RESULTS["cpu_load"]="PASS"
        ((PASSED_CHECKS++))
        return 0
    else
        warning "CPU load is high ($load_percent%)"
        RESULTS["cpu_load"]="WARN"
        ((WARNINGS++))
        send_alert "WARNING" "CPU load is ${load_percent}%" "cpu"
        return 1
    fi
}

# Check SSL certificate expiry
check_ssl_cert() {
    ((TOTAL_CHECKS++))
    
    local cert_file="/opt/panel-tk/certs/panel-tk.crt"
    
    if [[ -f "$cert_file" ]]; then
        local expiry_date
        local days_until_expiry
        
        expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
        days_until_expiry=$(( ($(date -d "$expiry_date" +%s) - $(date +%s)) / 86400 ))
        
        if [[ $days_until_expiry -gt 30 ]]; then
            success "SSL certificate is valid for $days_until_expiry days"
            RESULTS["ssl_cert"]="PASS"
            ((PASSED_CHECKS++))
            return 0
        else
            warning "SSL certificate expires in $days_until_expiry days"
            RESULTS["ssl_cert"]="WARN"
            ((WARNINGS++))
            send_alert "WARNING" "SSL certificate expires in ${days_until_expiry} days" "ssl"
            return 1
        fi
    else
        error "SSL certificate file not found"
        RESULTS["ssl_cert"]="FAIL"
        ((FAILED_CHECKS++))
        send_alert "CRITICAL" "SSL certificate file missing" "ssl"
        return 1
    fi
}

# Check log file sizes
check_log_sizes() {
    ((TOTAL_CHECKS++))
    
    local log_dir="/var/log/panel-tk"
    local max_size=104857600  # 100MB in bytes
    
    if [[ -d "$log_dir" ]]; then
        local large_logs
        large_logs=$(find "$log_dir" -type f -size +${max_size}c -exec ls -lh {} \; 2>/dev/null || true)
        
        if [[ -z "$large_logs" ]]; then
            success "Log files are within size limits"
            RESULTS["log_sizes"]="PASS"
            ((PASSED_CHECKS++))
            return 0
        else
            warning "Large log files detected"
            echo "$large_logs" | while read -r line; do
                warning "Large log file: $line"
            done
            RESULTS["log_sizes"]="WARN"
            ((WARNINGS++))
            send_alert "WARNING" "Large log files detected" "logs"
            return 1
        fi
    else
        warning "Log directory not found"
        RESULTS["log_sizes"]="WARN"
        ((WARNINGS++))
        return 1
    fi
}

# Check Docker container health
check_container_health() {
    local container=$1
    
    ((TOTAL_CHECKS++))
    
    local health_status
    health_status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
    
    if [[ "$health_status" == "healthy" ]]; then
        success "Container $container is healthy"
        RESULTS["container_$container"]="PASS"
        ((PASSED_CHECKS++))
        return 0
    else
        error "Container $container is not healthy (status: $health_status)"
        RESULTS["container_$container"]="FAIL"
        ((FAILED_CHECKS++))
        send_alert "CRITICAL" "Container $container health check failed" "docker"
        return 1
    fi
}

# Check application-specific endpoints
check_application_endpoints() {
    local base_url="${APP_URL:-http://localhost:3000}"
    
    check_http_endpoint "API Health" "$base_url/api/health"
    check_http_endpoint "API Status" "$base_url/api/status"
    check_http_endpoint "Dashboard" "$base_url/dashboard"
    check_http_endpoint "Login Page" "$base_URL/login"
}

# Generate health report
generate_report() {
    local report_file="/var/log/panel-tk/health-report-$(date +%Y%m%d-%H%M%S).json"
    
    cat > "$report_file" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "total_checks": $TOTAL_CHECKS,
    "passed_checks": $PASSED_CHECKS,
    "failed_checks": $FAILED_CHECKS,
    "warnings": $WARNINGS,
    "success_rate": $(( (PASSED_CHECKS * 100) / TOTAL_CHECKS )),
    "results": {
EOF
    
    local first=true
    for key in "${!RESULTS[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo "," >> "$report_file"
        fi
        echo "        \"$key\": \"${RESULTS[$key]}\"" >> "$report_file"
    done
    
    cat >> "$report_file" << EOF
    }
}
EOF
    
    info "Health report generated: $report_file"
}

# Main health check function
main() {
    log "Starting health check..."
    
    load_config
    
    # Change to project directory
    cd "$PROJECT_ROOT"
    
    # Load environment variables
    if [[ -f .env ]]; then
        source .env
    fi
    
    # Docker services
    check_service "PostgreSQL" "postgres"
    check_service "Redis" "redis"
    check_service "Application" "app"
    check_service "Nginx" "nginx"
    check_service "Prometheus" "prometheus"
    
    # Container health checks
    check_container_health "app"
    check_container_health "postgres"
    check_container_health "redis"
    
    # Database and cache
    check_database
    check_redis
    
    # System resources
    check_disk_space
    check_memory
    check_cpu_load
    
    # SSL and security
    check_ssl_cert
    
    # Logs
    check_log_sizes
    
    # Application endpoints
    check_application_endpoints
    
    # Generate report
    generate_report
    
    # Summary
    echo ""
    echo "=== Health Check Summary ==="
    echo "Total checks: $TOTAL_CHECKS"
    echo "Passed: $PASSED_CHECKS"
    echo "Failed: $FAILED_CHECKS"
    echo "Warnings: $WARNINGS"
    echo "Success rate: $(( (PASSED_CHECKS * 100) / TOTAL_CHECKS ))%"
    
    if [[ $FAILED_CHECKS -gt 0 ]]; then
        error "Health check completed with failures"
        exit 1
    elif [[ $WARNINGS -gt 0 ]]; then
        warning "Health check completed with warnings"
        exit 2
    else
        success "All health checks passed"
        exit 0
    fi
}

# Handle command line arguments
case "${1:-}" in
    --help|-h)
        echo "PanelTK Health Check Script"
        echo ""
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --help, -h     Show this help message"
        echo "  --quiet, -q    Run quietly (only show errors)"
        echo "  --json         Output results in JSON format"
        echo "  --webhook URL  Send alerts to webhook URL"
        echo ""
        exit 0
        ;;
    --quiet|-q)
        exec >/dev/null 2>&1
        ;;
    --json)
        main | jq -R . 2>/dev/null || main
        ;;
    --webhook)
        WEBHOOK_URL="${2:-}"
        shift 2
        ;;
esac

# Run main function
main "$@"
