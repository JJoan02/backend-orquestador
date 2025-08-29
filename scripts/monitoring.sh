#!/bin/bash
# PanelTK Monitoring Script
# Real-time monitoring and alerting for PanelTK infrastructure

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="/opt/panel-tk/config/monitoring.conf"
LOG_FILE="/var/log/panel-tk/monitoring.log"
METRICS_FILE="/var/log/panel-tk/metrics.json"
ALERT_FILE="/var/log/panel-tk/alerts.log"
PID_FILE="/var/run/panel-tk-monitoring.pid"

# Default thresholds
CPU_THRESHOLD=80
MEMORY_THRESHOLD=80
DISK_THRESHOLD=85
RESPONSE_TIME_THRESHOLD=5000  # milliseconds
ERROR_RATE_THRESHOLD=5        # percentage
CONNECTION_THRESHOLD=1000

# Monitoring state
declare -A METRICS
declare -A ALERTS
MONITORING_INTERVAL=30
IS_RUNNING=false

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
    [[ -n "${MONITORING_INTERVAL:-}" ]] && MONITORING_INTERVAL="$MONITORING_INTERVAL"
    [[ -n "${CPU_THRESHOLD:-}" ]] && CPU_THRESHOLD="$CPU_THRESHOLD"
    [[ -n "${MEMORY_THRESHOLD:-}" ]] && MEMORY_THRESHOLD="$MEMORY_THRESHOLD"
    [[ -n "${DISK_THRESHOLD:-}" ]] && DISK_THRESHOLD="$DISK_THRESHOLD"
    [[ -n "${RESPONSE_TIME_THRESHOLD:-}" ]] && RESPONSE_TIME_THRESHOLD="$RESPONSE_TIME_THRESHOLD"
    [[ -n "${ERROR_RATE_THRESHOLD:-}" ]] && ERROR_RATE_THRESHOLD="$ERROR_RATE_THRESHOLD"
    [[ -n "${CONNECTION_THRESHOLD:-}" ]] && CONNECTION_THRESHOLD="$CONNECTION_THRESHOLD"
}

# Initialize monitoring
init_monitoring() {
    mkdir -p "$(dirname "$LOG_FILE")"
    mkdir -p "$(dirname "$METRICS_FILE")"
    mkdir -p "$(dirname "$ALERT_FILE")"
    
    # Create PID file
    echo $$ > "$PID_FILE"
    
    # Load environment
    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        source "$PROJECT_ROOT/.env"
    fi
    
    load_config
    
    IS_RUNNING=true
    log "Monitoring initialized with interval ${MONITORING_INTERVAL}s"
}

# Cleanup on exit
cleanup() {
    IS_RUNNING=false
    rm -f "$PID_FILE"
    log "Monitoring stopped"
    exit 0
}

# Collect system metrics
collect_system_metrics() {
    # CPU usage
    local cpu_usage
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//' | sed 's/,//')
    METRICS["cpu_usage"]="${cpu_usage:-0}"
    
    # Memory usage
    local memory_total
    local memory_used
    local memory_usage
    
    memory_total=$(free -m | awk 'NR==2{print $2}')
    memory_used=$(free -m | awk 'NR==2{print $3}')
    memory_usage=$(echo "scale=2; $memory_used * 100 / $memory_total" | bc -l)
    METRICS["memory_usage"]="${memory_usage:-0}"
    METRICS["memory_total"]="${memory_total:-0}"
    METRICS["memory_used"]="${memory_used:-0}"
    
    # Disk usage
    local disk_usage
    disk_usage=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
    METRICS["disk_usage"]="${disk_usage:-0}"
    
    # Load average
    local load_avg
    load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    METRICS["load_avg"]="${load_avg:-0}"
    
    # Network connections
    local connections
    connections=$(netstat -an | grep ESTABLISHED | wc -l)
    METRICS["connections"]="${connections:-0}"
    
    # Uptime
    local uptime_seconds
    uptime_seconds=$(awk '{print $1}' /proc/uptime)
    METRICS["uptime"]="${uptime_seconds:-0}"
}

# Collect Docker metrics
collect_docker_metrics() {
    local containers
    containers=$(docker ps --format "{{.Names}}" 2>/dev/null || true)
    
    for container in $containers; do
        # Container stats
        local stats
        stats=$(docker stats --no-stream --format "table {{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" "$container" 2>/dev/null || echo -e "0.00%\t0B / 0B\t0B / 0B\t0B / 0B")
        
        local cpu_usage
        local memory_usage
        
        cpu_usage=$(echo "$stats" | tail -n +2 | awk '{print $1}' | sed 's/%//')
        memory_usage=$(echo "$stats" | tail -n +2 | awk '{print $2}' | sed 's/%//')
        
        METRICS["docker_${container}_cpu"]="${cpu_usage:-0}"
        METRICS["docker_${container}_memory"]="${memory_usage:-0}"
        
        # Container health
        local health_status
        health_status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
        METRICS["docker_${container}_health"]="$health_status"
    done
    
    METRICS["docker_containers_total"]=$(echo "$containers" | wc -l)
}

# Collect application metrics
collect_application_metrics() {
    local base_url="${APP_URL:-http://localhost:3000}"
    
    # API response time
    local response_time
    response_time=$(curl -o /dev/null -s -w "%{time_total}" "$base_url/api/health" 2>/dev/null || echo "0")
    response_time_ms=$(echo "$response_time * 1000" | bc -l | cut -d. -f1)
    METRICS["api_response_time"]="${response_time_ms:-0}"
    
    # API status
    local api_status
    api_status=$(curl -o /dev/null -s -w "%{http_code}" "$base_url/api/health" 2>/dev/null || echo "000")
    METRICS["api_status"]="$api_status"
    
    # Active users (if endpoint exists)
    local active_users
    active_users=$(curl -s "$base_url/api/metrics/active-users" 2>/dev/null | jq -r '.count' 2>/dev/null || echo "0")
    METRICS["active_users"]="${active_users:-0}"
    
    # Database connections
    local db_connections
    db_connections=$(PGPASSWORD="${DB_PASSWORD:-}" psql -h "${DB_HOST:-localhost}" -U "${DB_USER:-paneltk}" -d "${DB_NAME:-panel_tk}" -t -c "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null | xargs || echo "0")
    METRICS["db_connections"]="${db_connections:-0}"
}

# Check thresholds and generate alerts
check_thresholds() {
    local alert_generated=false
    
    # CPU threshold
    if (( $(echo "${METRICS[cpu_usage]} > $CPU_THRESHOLD" | bc -l) )); then
        if [[ "${ALERTS[cpu]}" != "active" ]]; then
            warning "CPU usage above threshold: ${METRICS[cpu_usage]}% > $CPU_THRESHOLD%"
            ALERTS["cpu"]="active"
            alert_generated=true
        fi
    else
        ALERTS["cpu"]="inactive"
    fi
    
    # Memory threshold
    if (( $(echo "${METRICS[memory_usage]} > $MEMORY_THRESHOLD" | bc -l) )); then
        if [[ "${ALERTS[memory]}" != "active" ]]; then
            warning "Memory usage above threshold: ${METRICS[memory_usage]}% > $MEMORY_THRESHOLD%"
            ALERTS["memory"]="active"
            alert_generated=true
        fi
    else
        ALERTS["memory"]="inactive"
    fi
    
    # Disk threshold
    if [[ ${METRICS[disk_usage]} -gt $DISK_THRESHOLD ]]; then
        if [[ "${ALERTS[disk]}" != "active" ]]; then
            warning "Disk usage above threshold: ${METRICS[disk_usage]}% > $DISK_THRESHOLD%"
            ALERTS["disk"]="active"
            alert_generated=true
        fi
    else
        ALERTS["disk"]="inactive"
    fi
    
    # Response time threshold
    if [[ ${METRICS[api_response_time]} -gt $RESPONSE_TIME_THRESHOLD ]]; then
        if [[ "${ALERTS[response_time]}" != "active" ]]; then
            warning "API response time above threshold: ${METRICS[api_response_time]}ms > ${RESPONSE_TIME_THRESHOLD}ms"
            ALERTS[response_time]="active"
            alert_generated=true
        fi
    else
        ALERTS[response_time]="inactive"
    fi
    
    # Database connections threshold
    if [[ ${METRICS[db_connections]} -gt $CONNECTION_THRESHOLD ]]; then
        if [[ "${ALERTS[db_connections]}" != "active" ]]; then
            warning "Database connections above threshold: ${METRICS[db_connections]} > $CONNECTION_THRESHOLD"
            ALERTS[db_connections]="active"
            alert_generated=true
        fi
    else
        ALERTS[db_connections]="inactive"
    fi
    
    # Container health alerts
    for key in "${!METRICS[@]}"; do
        if [[ $key == docker_*_health ]]; then
            local container_name=${key#docker_}
            container_name=${container_name%_health}
            
            if [[ "${METRICS[$key]}" != "healthy" ]]; then
                if [[ "${ALERTS[container_$container_name]}" != "active" ]]; then
                    warning "Container $container_name health check failed: ${METRICS[$key]}"
                    ALERTS[container_$container_name]="active"
                    alert_generated=true
                fi
            else
                ALERTS[container_$container_name]="inactive"
            fi
        fi
    done
    
    if [[ "$alert_generated" == "true" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ALERT: Threshold exceeded" >> "$ALERT_FILE"
    fi
}

# Save metrics to file
save_metrics() {
    local timestamp=$(date -Iseconds)
    
    cat > "$METRICS_FILE" << EOF
{
    "timestamp": "$timestamp",
    "metrics": {
EOF
    
    local first=true
    for key in "${!METRICS[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo "," >> "$METRICS_FILE"
        fi
        echo "        \"$key\": \"${METRICS[$key]}\"" >> "$METRICS_FILE"
    done
    
    cat >> "$METRICS_FILE" << EOF
    },
    "alerts": {
EOF
    
    first=true
    for key in "${!ALERTS[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo "," >> "$METRICS_FILE"
        fi
        echo "        \"$key\": \"${ALERTS[$key]}\"" >> "$METRICS_FILE"
    done
    
    cat >> "$METRICS_FILE" << EOF
    }
}
EOF
}

# Display current metrics
display_metrics() {
    clear
    echo "=== PanelTK Monitoring Dashboard ==="
    echo "Last update: $(date)"
    echo ""
    
    echo "System Metrics:"
    printf "  CPU Usage: %.2f%%\n" "${METRICS[cpu_usage]}"
    printf "  Memory: %.2f%% (%sMB / %sMB)\n" "${METRICS[memory_usage]}" "${METRICS[memory_used]}" "${METRICS[memory_total]}"
    printf "  Disk Usage: %s%%\n" "${METRICS[disk_usage]}"
    printf "  Load Average: %s\n" "${METRICS[load_avg]}"
    printf "  Network Connections: %s\n" "${METRICS[connections]}"
    printf "  Uptime: %s seconds\n" "${METRICS[uptime]}"
    echo ""
    
    echo "Application Metrics:"
    printf "  API Response Time: %sms\n" "${METRICS[api_response_time]}"
    printf "  API Status: %s\n" "${METRICS[api_status]}"
    printf "  Active Users: %s\n" "${METRICS[active_users]}"
    printf "  DB Connections: %s\n" "${METRICS[db_connections]}"
    echo ""
    
    echo "Docker Containers:"
    for key in "${!METRICS[@]}"; do
        if [[ $key == docker_*_cpu ]]; then
            local container_name=${key#docker_}
            container_name=${container_name%_cpu}
            printf "  %s: CPU %.2f%%, Memory %.2f%%\n" "$container_name" "${METRICS[$key]}" "${METRICS[docker_${container_name}_memory]}"
        fi
    done
    
    echo ""
    echo "Active Alerts:"
    local has_alerts=false
    for key in "${!ALERTS[@]}"; do
        if [[ "${ALERTS[$key]}" == "active" ]]; then
            echo "  - $key"
            has_alerts=true
        fi
    done
    
    if [[ "$has_alerts" == "false" ]]; then
        echo "  No active alerts"
    fi
}

# Main monitoring loop
monitor_loop() {
    init_monitoring
    
    # Set up signal handlers
    trap cleanup SIGTERM SIGINT
    
    log "Starting monitoring loop with ${MONITORING_INTERVAL}s interval"
    
    while $IS_RUNNING; do
        collect_system_metrics
        collect_docker_metrics
        collect_application_metrics
        check_thresholds
        save_metrics
        
        if [[ "${1:-}" == "--display" ]]; then
            display_metrics
        fi
        
        sleep "$MONITORING_INTERVAL"
    done
}

# Handle command line arguments
case "${1:-}" in
    --help|-h)
        echo "PanelTK Monitoring Script"
        echo ""
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --help, -h         Show this help message"
        echo "  --start            Start monitoring daemon"
        echo "  --stop             Stop monitoring daemon"
        echo "  --status           Show monitoring status"
        echo "  --display          Show live metrics display"
        echo "  --once             Run metrics collection once"
        echo "  --config FILE      Use custom config file"
        echo ""
        exit 0
        ;;
    --start)
        if [[ -f "$PID_FILE" ]]; then
            error "Monitoring is already running (PID: $(cat "$PID_FILE"))"
            exit 1
        fi
        
        nohup "$0" --daemon >/dev/null 2>&1 &
        success "Monitoring started (PID: $!)"
        ;;
    --stop)
        if [[ -f "$PID_FILE" ]]; then
            local pid=$(cat "$PID_FILE")
            kill "$pid" 2>/dev/null || true
            rm -f "$PID_FILE"
            success "Monitoring stopped"
        else
            error "Monitoring is not running"
            exit 1
        fi
        ;;
    --status)
        if [[ -f "$PID_FILE" ]]; then
            local pid=$(cat "$PID_FILE")
            if kill -0 "$pid" 2>/dev/null; then
                success "Monitoring is running (PID: $pid)"
            else
                error "Monitoring is not running (stale PID file)"
                rm -f "$PID_FILE"
            fi
        else
            error "Monitoring is not running"
        fi
        ;;
    --display)
        monitor_loop --display
        ;;
    --once)
        init_monitoring
        collect_system_metrics
        collect_docker_metrics
        collect_application_metrics
        check_thresholds
        save_metrics
        display_metrics
        ;;
    --daemon)
        monitor_loop
        ;;
    --config)
        CONFIG_FILE="${2:-$CONFIG_FILE}"
        shift 2
        monitor_loop
        ;;
    *)
        monitor_loop
        ;;
esac
