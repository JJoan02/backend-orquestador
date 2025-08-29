#!/bin/bash

# PanelTK Restore Monitor
# Real-time monitoring and alerting for restore operations

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/app/config/restore-config.yml"
LOG_FILE="/app/logs/restore-monitor.log"
METRICS_FILE="/app/metrics/restore-metrics.json"
ALERT_FILE="/app/alerts/restore-alerts.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default thresholds
DEFAULT_CPU_THRESHOLD=80
DEFAULT_MEMORY_THRESHOLD=85
DEFAULT_DISK_THRESHOLD=90
DEFAULT_NETWORK_THRESHOLD=1000  # MB/s

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
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$METRICS_FILE")" "$(dirname "$ALERT_FILE")"

# Function to load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Loading configuration from $CONFIG_FILE"
        
        # Load thresholds
        CPU_THRESHOLD=$(yq eval '.monitoring.thresholds.cpu // 80' "$CONFIG_FILE")
        MEMORY_THRESHOLD=$(yq eval '.monitoring.thresholds.memory // 85' "$CONFIG_FILE")
        DISK_THRESHOLD=$(yq eval '.monitoring.thresholds.disk // 90' "$CONFIG_FILE")
        NETWORK_THRESHOLD=$(yq eval '.monitoring.thresholds.network // 1000' "$CONFIG_FILE")
        
        # Load alert channels
        SLACK_WEBHOOK=$(yq eval '.monitoring.alerts.slack.webhook // ""' "$CONFIG_FILE")
        DISCORD_WEBHOOK=$(yq eval '.monitoring.alerts.discord.webhook // ""' "$CONFIG_FILE")
        EMAIL_TO=$(yq eval '.monitoring.alerts.email.to // ""' "$CONFIG_FILE")
    else
        warning "Configuration file not found, using defaults"
        CPU_THRESHOLD=$DEFAULT_CPU_THRESHOLD
        MEMORY_THRESHOLD=$DEFAULT_MEMORY_THRESHOLD
        DISK_THRESHOLD=$DEFAULT_DISK_THRESHOLD
        NETWORK_THRESHOLD=$DEFAULT_NETWORK_THRESHOLD
    fi
}

# Function to get system metrics
get_system_metrics() {
    local metrics_file="$1"
    
    # CPU usage
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//')
    
    # Memory usage
    local memory_info=$(free -m | awk 'NR==2{printf "%.2f", $3*100/$2}')
    
    # Disk usage
    local disk_usage=$(df /app | tail -1 | awk '{print $5}' | sed 's/%//')
    
    # Network usage
    local network_rx=$(cat /proc/net/dev | grep eth0 | awk '{print $2}')
    local network_tx=$(cat /proc/net/dev | grep eth0 | awk '{print $10}')
    
    # Docker stats
    local docker_stats=$(docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}")
    
    # Create metrics JSON
    cat > "$metrics_file" <<EOF
{
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "system": {
        "cpu_usage": $cpu_usage,
        "memory_usage": $memory_info,
        "disk_usage": $disk_usage,
        "network_rx": $network_rx,
        "network_tx": $network_tx
    },
    "docker": {
        "stats": "$docker_stats"
    }
}
EOF
}

# Function to check restore progress
check_restore_progress() {
    local restore_pid_file="/tmp/restore.pid"
    
    if [[ -f "$restore_pid_file" ]]; then
        local restore_pid=$(cat "$restore_pid_file")
        
        if kill -0 "$restore_pid" 2>/dev/null; then
            # Get restore progress
            local restore_log="/app/logs/restore-manager.log"
            local progress=$(grep -o "Progress: [0-9]*%" "$restore_log" | tail -1 || echo "Progress: 0%")
            
            echo "$progress"
            return 0
        else
            echo "Restore process not running"
            return 1
        fi
    else
        echo "No restore process found"
        return 1
    fi
}

# Function to check service health
check_service_health() {
    local services=("postgres" "redis" "app" "nginx")
    local health_status=()
    
    for service in "${services[@]}"; do
        if docker-compose ps "$service" | grep -q "Up"; then
            health_status+=("{\"service\":\"$service\",\"status\":\"healthy\"}")
        else
            health_status+=("{\"service\":\"$service\",\"status\":\"unhealthy\"}")
        fi
    done
    
    echo "[${health_status[*]}]"
}

# Function to check backup integrity
check_backup_integrity() {
    local backup_file="$1"
    
    if [[ -f "$backup_file" ]]; then
        # Check file integrity
        if tar -tzf "$backup_file" >/dev/null 2>&1; then
            echo "valid"
        else
            echo "corrupted"
        fi
    else
        echo "missing"
    fi
}

# Function to generate alerts
generate_alerts() {
    local alerts_file="$1"
    local metrics_file="$2"
    
    local alerts=()
    
    # Load metrics
    local cpu_usage=$(jq -r '.system.cpu_usage' "$metrics_file")
    local memory_usage=$(jq -r '.system.memory_usage' "$metrics_file")
    local disk_usage=$(jq -r '.system.disk_usage' "$metrics_file")
    
    # Check CPU threshold
    if (( $(echo "$cpu_usage > $CPU_THRESHOLD" | bc -l) )); then
        alerts+=("{\"type\":\"cpu\",\"severity\":\"warning\",\"message\":\"CPU usage above threshold: ${cpu_usage}%\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}")
    fi
    
    # Check memory threshold
    if (( $(echo "$memory_usage > $MEMORY_THRESHOLD" | bc -l) )); then
        alerts+=("{\"type\":\"memory\",\"severity\":\"warning\",\"message\":\"Memory usage above threshold: ${memory_usage}%\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}")
    fi
    
    # Check disk threshold
    if [[ $disk_usage -gt $DISK_THRESHOLD ]]; then
        alerts+=("{\"type\":\"disk\",\"severity\":\"critical\",\"message\":\"Disk usage above threshold: ${disk_usage}%\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}")
    fi
    
    # Create alerts JSON
    cat > "$alerts_file" <<EOF
{
    "alerts": [${alerts[@]:-}]
}
EOF
}

# Function to send alerts
send_alerts() {
    local alerts_file="$1"
    
    local alert_count=$(jq '.alerts | length' "$alerts_file")
    
    if [[ $alert_count -gt 0 ]]; then
        info "Sending $alert_count alerts..."
        
        # Send to Slack
        if [[ -n "${SLACK_WEBHOOK:-}" ]]; then
            jq -r '.alerts[] | "\(.severity): \(.message)"' "$alerts_file" | while read alert; do
                curl -X POST -H 'Content-type: application/json' \
                    --data "{\"text\":\"PanelTK Monitor Alert: $alert\"}" \
                    "$SLACK_WEBHOOK"
            done
        fi
        
        # Send to Discord
        if [[ -n "${DISCORD_WEBHOOK:-}" ]]; then
            jq -r '.alerts[] | "\(.severity): \(.message)"' "$alerts_file" | while read alert; do
                curl -X POST -H 'Content-type: application/json' \
                    --data "{\"content\":\"PanelTK Monitor Alert: $alert\"}" \
                    "$DISCORD_WEBHOOK"
            done
        fi
        
        # Send email
        if [[ -n "${EMAIL_TO:-}" ]]; then
            local email_body=$(jq -r '.alerts[] | "- \(.severity): \(.message) (\(.timestamp))"' "$alerts_file")
            echo "$email_body" | mail -s "PanelTK Monitor Alerts" "$EMAIL_TO"
        fi
    fi
}

# Function to monitor restore operation
monitor_restore() {
    local restore_pid="$1"
    
    info "Monitoring restore operation (PID: $restore_pid)..."
    
    while kill -0 "$restore_pid" 2>/dev/null; do
        # Get system metrics
        get_system_metrics "$METRICS_FILE"
        
        # Check service health
        local health_status=$(check_service_health)
        echo "$health_status" > "/tmp/service-health.json"
        
        # Generate alerts
        generate_alerts "$ALERT_FILE" "$METRICS_FILE"
        
        # Send alerts
        send_alerts "$ALERT_FILE"
        
        # Log progress
        local progress=$(check_restore_progress)
        info "Restore progress: $progress"
        
        sleep 30
    done
    
    info "Restore operation completed"
}

# Function to continuous monitoring
continuous_monitoring() {
    info "Starting continuous monitoring..."
    
    while true; do
        # Get system metrics
        get_system_metrics "$METRICS_FILE"
        
        # Check service health
        local health_status=$(check_service_health)
        echo "$health_status" > "/tmp/service-health.json"
        
        # Generate alerts
        generate_alerts "$ALERT_FILE" "$METRICS_FILE"
        
        # Send alerts
        send_alerts "$ALERT_FILE"
        
        # Log status
        info "Monitoring cycle completed"
        
        sleep 60
    done
}

# Function to generate monitoring report
generate_report() {
    local report_file="$1"
    
    info "Generating monitoring report..."
    
    # Get current metrics
    get_system_metrics "$METRICS_FILE"
    
    # Get service health
    local health_status=$(check_service_health)
    
    # Get backup status
    local latest_backup=$(ls -t /app/backups/*.tar.gz 2>/dev/null | head -1 || echo "No backups found")
    local backup_integrity="unknown"
    
    if [[ -f "$latest_backup" ]]; then
        backup_integrity=$(check_backup_integrity "$latest_backup")
    fi
    
    # Generate report
    cat > "$report_file" <<EOF
# PanelTK Restore Monitoring Report
Generated: $(date)

## System Status
$(cat "$METRICS_FILE")

## Service Health
$health_status

## Backup Status
- Latest Backup: $latest_backup
- Integrity: $backup_integrity

## Recent Alerts
$(tail -n 50 "$LOG_FILE" | grep -E "(WARNING|ERROR|CRITICAL)")

## Recommendations
$(if [[ $backup_integrity != "valid" ]]; then
    echo "- Backup integrity check failed - consider creating new backup"
fi)

$(if [[ $(jq -r '.system.disk_usage' "$METRICS_FILE") -gt 85 ]]; then
    echo "- Disk usage is high - consider cleanup or expansion"
fi)

$(if [[ $(jq -r '.system.memory_usage' "$METRICS_FILE") -gt 80 ]]; then
    echo "- Memory usage is high - consider optimization"
fi)
EOF
    
    success "Report generated: $report_file"
}

# Main function
main() {
    load_config
    
    case "${1:-}" in
        "monitor")
            monitor_restore "${2:-}"
            ;;
        "continuous")
            continuous_monitoring
            ;;
        "report")
            generate_report "${2:-/tmp/monitoring-report.md}"
            ;;
        "health")
            check_service_health
            ;;
        "alerts")
            generate_alerts "$ALERT_FILE" "$METRICS_FILE"
            send_alerts "$ALERT_FILE"
            ;;
        *)
            echo "Usage: $0 {monitor|continuous|report|health|alerts}"
            echo "  monitor <pid>    - Monitor specific restore operation"
            echo "  continuous       - Start continuous monitoring"
            echo "  report [file]    - Generate monitoring report"
            echo "  health           - Check service health"
            echo "  alerts           - Generate and send alerts"
            exit 1
            ;;
    esac
}

# Handle command line arguments
main "$@"
