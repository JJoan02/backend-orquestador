#!/bin/bash

# PanelTK Restore Dashboard
# Interactive dashboard for restore operations monitoring and management

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTORE_DIR="/app/restore"
LOG_DIR="/app/logs"
CONFIG_FILE="/app/config/restore-config.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Dashboard state
DASHBOARD_REFRESH=5
SHOW_HELP=false

# Function to clear screen
clear_screen() {
    clear
}

# Function to print header
print_header() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                    PanelTK Restore Operations Dashboard                      ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Function to print footer
print_footer() {
    echo -e "${CYAN}"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Function to get system stats
get_system_stats() {
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    local memory_usage=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100.0}')
    local disk_usage=$(df /app | tail -1 | awk '{print $5}' | sed 's/%//')
    
    echo "$cpu_usage|$memory_usage|$disk_usage"
}

# Function to get restore operations
get_restore_operations() {
    local operations=()
    
    for dir in "$RESTORE_DIR"/restore-*; do
        if [[ -d "$dir" ]]; then
            local id=$(basename "$dir")
            local status="UNKNOWN"
            local start_time=""
            local end_time=""
            local duration=""
            
            if [[ -f "$dir/final-report.json" ]]; then
                status=$(jq -r '.status' "$dir/final-report.json" 2>/dev/null || echo "UNKNOWN")
                start_time=$(jq -r '.start_time' "$dir/final-report.json" 2>/dev/null || echo "")
                end_time=$(jq -r '.end_time' "$dir/final-report.json" 2>/dev/null || echo "")
                
                if [[ -n "$start_time" && -n "$end_time" ]]; then
                    local start_epoch=$(date -d "$start_time" +%s 2>/dev/null || echo 0)
                    local end_epoch=$(date -d "$end_time" +%s 2>/dev/null || echo 0)
                    duration=$((end_epoch - start_epoch))
                fi
            elif [[ -f "$dir/orchestration.json" ]]; then
                status=$(jq -r '.status' "$dir/orchestration.json" 2>/dev/null || echo "UNKNOWN")
                start_time=$(jq -r '.start_time' "$dir/orchestration.json" 2>/dev/null || echo "")
            fi
            
            operations+=("$id|$status|$start_time|$end_time|$duration")
        fi
    done
    
    printf '%s\n' "${operations[@]}"
}

# Function to get active services
get_active_services() {
    local services=()
    
    while IFS= read -r line; do
        if [[ $line =~ ^[a-zA-Z0-9_-]+ ]]; then
            local name=$(echo "$line" | awk '{print $1}')
            local status=$(echo "$line" | awk '{print $2}')
            local ports=$(echo "$line" | awk '{print $3}')
            services+=("$name|$status|$ports")
        fi
    done < <(docker-compose ps --services 2>/dev/null | head -20)
    
    printf '%s\n' "${services[@]}"
}

# Function to get recent logs
get_recent_logs() {
    local log_file="$LOG_DIR/restore-orchestrator.log"
    if [[ -f "$log_file" ]]; then
        tail -n 10 "$log_file" | sed 's/\[.*\] //' | sed 's/\x1b\[[0-9;]*m//g'
    fi
}

# Function to format duration
format_duration() {
    local seconds=$1
    if [[ $seconds -lt 60 ]]; then
        echo "${seconds}s"
    elif [[ $seconds -lt 3600 ]]; then
        echo "$((seconds / 60))m $((seconds % 60))s"
    else
        echo "$((seconds / 3600))h $(((seconds % 3600) / 60))m"
    fi
}

# Function to get status color
get_status_color() {
    local status=$1
    case $status in
        "COMPLETED"|"SUCCESS") echo "$GREEN" ;;
        "FAILED"|"ERROR") echo "$RED" ;;
        "RUNNING"|"IN_PROGRESS") echo "$YELLOW" ;;
        "PENDING"|"INITIALIZING") echo "$BLUE" ;;
        *) echo "$WHITE" ;;
    esac
}

# Function to display system overview
display_system_overview() {
    local stats=($(echo "$(get_system_stats)" | tr '|' ' '))
    
    echo -e "${WHITE}System Overview:${NC}"
    echo -e "  CPU Usage: ${stats[0]}%"
    echo -e "  Memory Usage: ${stats[1]}%"
    echo -e "  Disk Usage: ${stats[2]}%"
    echo ""
}

# Function to display restore operations
display_restore_operations() {
    local operations=($(get_restore_operations))
    
    echo -e "${WHITE}Recent Restore Operations:${NC}"
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│ ID                    Status      Start Time           Duration           │${NC}"
    echo -e "${CYAN}├─────────────────────────────────────────────────────────────────────────────┤${NC}"
    
    if [[ ${#operations[@]} -eq 0 ]]; then
        echo -e "${CYAN}│ No restore operations found                                                 │${NC}"
    else
        for op in "${operations[@]}"; do
            IFS='|' read -r id status start_time end_time duration <<< "$op"
            local color=$(get_status_color "$status")
            local formatted_duration=$(format_duration "$duration")
            local short_id="${id:0:20}..."
            
            printf "${CYAN}│ ${NC}%-21s ${color}%-10s${NC} %-19s %-15s ${CYAN}│${NC}\n" \
                "$short_id" "$status" "${start_time:0:19}" "$formatted_duration"
        done
    fi
    
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# Function to display active services
display_active_services() {
    local services=($(get_active_services))
    
    echo -e "${WHITE}Active Services:${NC}"
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│ Service Name      Status      Ports                                        │${NC}"
    echo -e "${CYAN}├─────────────────────────────────────────────────────────────────────────────┤${NC}"
    
    if [[ ${#services[@]} -eq 0 ]]; then
        echo -e "${CYAN}│ No active services found                                                    │${NC}"
    else
        for svc in "${services[@]}"; do
            IFS='|' read -r name status ports <<< "$svc"
            local color=$(get_status_color "$status")
            printf "${CYAN}│ ${NC}%-17s ${color}%-10s${NC} %-40s ${CYAN}│${NC}\n" \
                "$name" "$status" "${ports:0:40}"
        done
    fi
    
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# Function to display recent logs
display_recent_logs() {
    local logs=($(get_recent_logs))
    
    echo -e "${WHITE}Recent Orchestrator Logs:${NC}"
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────────────────┐${NC}"
    
    if [[ ${#logs[@]} -eq 0 ]]; then
        echo -e "${CYAN}│ No recent logs found                                                        │${NC}"
    else
        for log in "${logs[@]}"; do
            printf "${CYAN}│ ${NC}%-75s ${CYAN}│${NC}\n" "${log:0:75}"
        done
    fi
    
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# Function to display help
display_help() {
    echo -e "${WHITE}Dashboard Commands:${NC}"
    echo -e "  ${GREEN}q${NC} - Quit dashboard"
    echo -e "  ${GREEN}r${NC} - Refresh immediately"
    echo -e "  ${GREEN}h${NC} - Toggle help"
    echo -e "  ${GREEN}1${NC} - View detailed restore operations"
    echo -e "  ${GREEN}2${NC} - View service logs"
    echo -e "  ${GREEN}3${NC} - View backup validation status"
    echo ""
}

# Function to view detailed operations
view_detailed_operations() {
    clear_screen
    print_header
    
    local operations=($(get_restore_operations))
    
    echo -e "${WHITE}Detailed Restore Operations:${NC}"
    echo ""
    
    if [[ ${#operations[@]} -eq 0 ]]; then
        echo "No restore operations found."
    else
        for op in "${operations[@]}"; do
            IFS='|' read -r id status start_time end_time duration <<< "$op"
            local color=$(get_status_color "$status")
            local formatted_duration=$(format_duration "$duration")
            
            echo -e "Operation: ${CYAN}$id${NC}"
            echo -e "Status: ${color}$status${NC}"
            echo -e "Start Time: $start_time"
            echo -e "End Time: ${end_time:-'N/A'}"
            echo -e "Duration: $formatted_duration"
            echo ""
            
            local report_file="$RESTORE_DIR/$id/final-report.json"
            if [[ -f "$report_file" ]]; then
                echo "Details:"
                jq -r '.details[]' "$report_file" 2>/dev/null || echo "No details available"
                echo ""
            fi
            
            echo "----------------------------------------"
            echo ""
        done
    fi
    
    echo -e "${YELLOW}Press any key to return to dashboard...${NC}"
    read -n 1 -s
}

# Function to view service logs
view_service_logs() {
    clear_screen
    print_header
    
    echo -e "${WHITE}Service Logs:${NC}"
    echo ""
    
    local log_files=(
        "$LOG_DIR/restore-orchestrator.log"
        "$LOG_DIR/restore-manager.log"
        "$LOG_DIR/restore-monitor.log"
        "$LOG_DIR/restore-validator.log"
    )
    
    for log_file in "${log_files[@]}"; do
        if [[ -f "$log_file" ]]; then
            echo -e "${CYAN}=== $(basename "$log_file") ===${NC}"
            tail -n 20 "$log_file" | sed 's/\x1b\[[0-9;]*m//g'
            echo ""
        fi
    done
    
    echo -e "${YELLOW}Press any key to return to dashboard...${NC}"
    read -n 1 -s
}

# Function to view backup validation
view_backup_validation() {
    clear_screen
    print_header
    
    echo -e "${WHITE}Backup Validation Status:${NC}"
    echo ""
    
    local validation_file="/app/restore/validation-report.json"
    if [[ -f "$validation_file" ]]; then
        jq -r '
            "Validation Date: " + .validation_date,
            "Backup Path: " + .backup_path,
            "Status: " + .status,
            "",
            "Checks:",
            (.checks[] | "  - " + .check + ": " + .status + " (" + .message + ")"),
            "",
            "Summary:",
            "  Total Checks: " + (.total_checks | tostring),
            "  Passed: " + (.passed | tostring),
            "  Failed: " + (.failed | tostring)
        ' "$validation_file"
    else
        echo "No validation report found."
    fi
    
    echo ""
    echo -e "${YELLOW}Press any key to return to dashboard...${NC}"
    read -n 1 -s
}

# Function to handle user input
handle_input() {
    local key=$1
    
    case $key in
        "q"|"Q")
            echo -e "\n${GREEN}Exiting dashboard...${NC}"
            exit 0
            ;;
        "r"|"R")
            return 0
            ;;
        "h"|"H")
            SHOW_HELP=$([ "$SHOW_HELP" = true ] && echo false || echo true)
            return 0
            ;;
        "1")
            view_detailed_operations
            return 0
            ;;
        "2")
            view_service_logs
            return 0
            ;;
        "3")
            view_backup_validation
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to check dependencies
check_dependencies() {
    local missing_deps=()
    
    command -v jq >/dev/null 2>&1 || missing_deps+=("jq")
    command -v docker-compose >/dev/null 2>&1 || missing_deps+=("docker-compose")
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo -e "${RED}Error: Missing dependencies: ${missing_deps[*]}${NC}"
        echo "Please install the missing dependencies and try again."
        exit 1
    fi
}

# Main dashboard loop
main() {
    check_dependencies
    
    echo -e "${GREEN}Starting PanelTK Restore Dashboard...${NC}"
    echo -e "${YELLOW}Press 'q' to quit, 'h' for help${NC}"
    sleep 2
    
    while true; do
        clear_screen
        print_header
        
        display_system_overview
        display_restore_operations
        display_active_services
        display_recent_logs
        
        if [[ "$SHOW_HELP" = true ]]; then
            display_help
        fi
        
        print_footer
        
        # Wait for input or timeout
        if read -t $DASHBOARD_REFRESH -n 1 key; then
            handle_input "$key"
        fi
    done
}

# Handle script interruption
trap 'echo -e "\n${GREEN}Dashboard interrupted. Exiting...${NC}"; exit 0' INT TERM

# Run main function
main "$@"
