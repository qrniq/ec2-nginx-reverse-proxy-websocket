#!/bin/bash

# Chrome Debugger Proxy Health Check Script
# Monitors nginx and Chrome debugger instances
# Provides detailed status information and automatic issue detection

set -euo pipefail

# Configuration
DEFAULT_PORT_RANGE_START=48000
DEFAULT_PORT_RANGE_END=49000
NGINX_CONF_DIR="/etc/nginx"
LOG_DIR="/var/log/nginx"
CHROME_LOG_DIR="/var/log/chrome-debug"
PID_DIR="/var/run/chrome-debug"
HEALTH_LOG="/var/log/chrome-proxy-health.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Status indicators
SUCCESS="✓"
FAILURE="✗"
WARNING="!"
INFO="i"

# Global status tracking
OVERALL_STATUS="healthy"
ISSUES_FOUND=0

log() {
    local level="${1:-INFO}"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Log to file
    echo "[$timestamp] [$level] $message" >> "$HEALTH_LOG"
    
    # Console output with colors
    case "$level" in
        "SUCCESS")
            echo -e "${GREEN}${SUCCESS}${NC} $message"
            ;;
        "FAILURE")
            echo -e "${RED}${FAILURE}${NC} $message"
            OVERALL_STATUS="unhealthy"
            ((ISSUES_FOUND++))
            ;;
        "WARNING")
            echo -e "${YELLOW}${WARNING}${NC} $message"
            if [[ "$OVERALL_STATUS" == "healthy" ]]; then
                OVERALL_STATUS="degraded"
            fi
            ((ISSUES_FOUND++))
            ;;
        "INFO")
            echo -e "${BLUE}${INFO}${NC} $message"
            ;;
        *)
            echo "$message"
            ;;
    esac
}

# Check if a service is running
check_service() {
    local service_name="$1"
    
    if systemctl is-active "$service_name" >/dev/null 2>&1; then
        log "SUCCESS" "$service_name service is running"
        return 0
    else
        log "FAILURE" "$service_name service is not running"
        return 1
    fi
}

# Check if nginx configuration is valid
check_nginx_config() {
    if nginx -t >/dev/null 2>&1; then
        log "SUCCESS" "nginx configuration is valid"
        return 0
    else
        log "FAILURE" "nginx configuration has errors"
        log "INFO" "Run 'nginx -t' for detailed error information"
        return 1
    fi
}

# Check if port is accessible
check_port_accessible() {
    local host="$1"
    local port="$2"
    local timeout="${3:-5}"
    
    if timeout "$timeout" bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Check HTTP endpoint
check_http_endpoint() {
    local url="$1"
    local expected_status="${2:-200}"
    local timeout="${3:-10}"
    
    local response
    response=$(curl -s -w "%{http_code}" -m "$timeout" "$url" 2>/dev/null || echo "000")
    local http_code="${response: -3}"
    
    if [[ "$http_code" == "$expected_status" ]]; then
        return 0
    else
        return 1
    fi
}

# Check WebSocket endpoint
check_websocket_endpoint() {
    local ws_url="$1"
    local timeout="${2:-10}"
    
    # Use a simple Node.js script to test WebSocket connection
    local test_script="/tmp/ws_test_$$.js"
    
    cat > "$test_script" << 'EOF'
const WebSocket = require('ws');
const url = process.argv[2];
const timeout = parseInt(process.argv[3]) * 1000;

const ws = new WebSocket(url);
let success = false;

const timeoutId = setTimeout(() => {
    if (!success) {
        console.log('TIMEOUT');
        process.exit(1);
    }
}, timeout);

ws.on('open', () => {
    success = true;
    clearTimeout(timeoutId);
    console.log('SUCCESS');
    ws.close();
    process.exit(0);
});

ws.on('error', (error) => {
    clearTimeout(timeoutId);
    console.log('ERROR:', error.message);
    process.exit(1);
});
EOF
    
    if command -v node >/dev/null 2>&1; then
        local result
        result=$(node "$test_script" "$ws_url" "$timeout" 2>&1)
        rm -f "$test_script"
        
        if [[ "$result" == "SUCCESS" ]]; then
            return 0
        else
            return 1
        fi
    else
        rm -f "$test_script"
        log "WARNING" "Node.js not available for WebSocket testing"
        return 1
    fi
}

# Check Chrome process
check_chrome_process() {
    local port="$1"
    local pid_file="$PID_DIR/chrome-$port.pid"
    
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        
        if kill -0 "$pid" 2>/dev/null; then
            log "SUCCESS" "Chrome process on port $port is running (PID: $pid)"
            return 0
        else
            log "FAILURE" "Chrome process on port $port is not running (stale PID file)"
            return 1
        fi
    else
        log "INFO" "No PID file found for Chrome on port $port"
        return 1
    fi
}

# Check Chrome debugger availability
check_chrome_debugger() {
    local port="$1"
    
    # Check if Chrome process is running
    if ! check_chrome_process "$port"; then
        return 1
    fi
    
    # Check if debugger port is accessible
    if ! check_port_accessible "localhost" "$port" 2; then
        log "FAILURE" "Chrome debugger port $port is not accessible"
        return 1
    fi
    
    # Check DevTools protocol endpoints
    local endpoints=("/json/version" "/json/list")
    
    for endpoint in "${endpoints[@]}"; do
        if check_http_endpoint "http://localhost:$port$endpoint" 200 5; then
            log "SUCCESS" "Chrome debugger endpoint $endpoint on port $port is working"
        else
            log "FAILURE" "Chrome debugger endpoint $endpoint on port $port is not working"
            return 1
        fi
    done
    
    return 0
}

# Check nginx proxy for Chrome port
check_nginx_proxy() {
    local port="$1"
    
    # Check if nginx is proxying this port
    local nginx_config="/etc/nginx/conf.d/chrome-proxy-$port.conf"
    
    if [[ ! -f "$nginx_config" ]]; then
        log "WARNING" "nginx proxy configuration for port $port not found"
        return 1
    fi
    
    # Check if proxy port is accessible through nginx
    if ! check_port_accessible "localhost" "$port" 2; then
        log "FAILURE" "nginx proxy port $port is not accessible"
        return 1
    fi
    
    # Check proxy endpoints
    local endpoints=("/json/version" "/json/list" "/health")
    
    for endpoint in "${endpoints[@]}"; do
        if check_http_endpoint "http://localhost:$port$endpoint" 200 5; then
            log "SUCCESS" "nginx proxy endpoint $endpoint on port $port is working"
        else
            if [[ "$endpoint" == "/health" ]]; then
                log "WARNING" "nginx proxy health endpoint on port $port is not working (optional)"
            else
                log "FAILURE" "nginx proxy endpoint $endpoint on port $port is not working"
                return 1
            fi
        fi
    done
    
    return 0
}

# Check system resources
check_system_resources() {
    log "INFO" "Checking system resources..."
    
    # Check memory usage
    local mem_usage
    mem_usage=$(free | awk 'NR==2{printf "%.2f", $3*100/$2}')
    
    if (( $(echo "$mem_usage > 90" | bc -l) )); then
        log "WARNING" "High memory usage: ${mem_usage}%"
    elif (( $(echo "$mem_usage > 80" | bc -l) )); then
        log "WARNING" "Moderate memory usage: ${mem_usage}%"
    else
        log "SUCCESS" "Memory usage is acceptable: ${mem_usage}%"
    fi
    
    # Check disk usage
    local disk_usage
    disk_usage=$(df / | awk 'NR==2{print $5}' | sed 's/%//')
    
    if (( disk_usage > 90 )); then
        log "FAILURE" "Critical disk usage: ${disk_usage}%"
    elif (( disk_usage > 80 )); then
        log "WARNING" "High disk usage: ${disk_usage}%"
    else
        log "SUCCESS" "Disk usage is acceptable: ${disk_usage}%"
    fi
    
    # Check load average
    local load_avg
    load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    local cpu_cores
    cpu_cores=$(nproc)
    
    if (( $(echo "$load_avg > $cpu_cores * 2" | bc -l) )); then
        log "WARNING" "High system load: $load_avg (cores: $cpu_cores)"
    else
        log "SUCCESS" "System load is acceptable: $load_avg (cores: $cpu_cores)"
    fi
}

# Check log files for errors
check_logs() {
    log "INFO" "Checking recent log entries for errors..."
    
    # Check nginx error log
    if [[ -f "$LOG_DIR/error.log" ]]; then
        local nginx_errors
        nginx_errors=$(tail -n 50 "$LOG_DIR/error.log" | grep -i error | wc -l)
        
        if (( nginx_errors > 10 )); then
            log "WARNING" "Found $nginx_errors recent nginx errors"
        elif (( nginx_errors > 0 )); then
            log "INFO" "Found $nginx_errors recent nginx errors (normal)"
        else
            log "SUCCESS" "No recent nginx errors found"
        fi
    fi
    
    # Check Chrome logs
    if [[ -d "$CHROME_LOG_DIR" ]]; then
        local chrome_errors=0
        
        for log_file in "$CHROME_LOG_DIR"/chrome-*.log; do
            if [[ -f "$log_file" ]]; then
                local errors
                errors=$(tail -n 20 "$log_file" | grep -i -E "(error|failed|crash)" | wc -l)
                chrome_errors=$((chrome_errors + errors))
            fi
        done
        
        if (( chrome_errors > 5 )); then
            log "WARNING" "Found $chrome_errors recent Chrome errors"
        elif (( chrome_errors > 0 )); then
            log "INFO" "Found $chrome_errors recent Chrome errors (normal)"
        else
            log "SUCCESS" "No recent Chrome errors found"
        fi
    fi
}

# Discover active Chrome ports
discover_chrome_ports() {
    local active_ports=()
    
    log "INFO" "Scanning for active Chrome debugger instances..."
    
    for ((port=$DEFAULT_PORT_RANGE_START; port<=$DEFAULT_PORT_RANGE_END; port++)); do
        if check_port_accessible "localhost" "$port" 1; then
            if check_http_endpoint "http://localhost:$port/json/version" 200 2; then
                active_ports+=("$port")
            fi
        fi
        
        # Limit scan to avoid timeout (check every 10th port after 48100)
        if (( port > 48100 && port % 10 != 0 )); then
            continue
        fi
    done
    
    echo "${active_ports[@]}"
}

# Generate health report
generate_health_report() {
    local active_ports=("$@")
    
    echo
    log "INFO" "=== Chrome Debugger Proxy Health Report ==="
    echo
    
    # nginx status
    echo -e "${CYAN}nginx Service:${NC}"
    check_service "nginx"
    check_nginx_config
    echo
    
    # Chrome instances status
    echo -e "${CYAN}Chrome Debugger Instances:${NC}"
    if [[ ${#active_ports[@]} -eq 0 ]]; then
        log "WARNING" "No active Chrome debugger instances found"
    else
        log "INFO" "Found ${#active_ports[@]} active Chrome debugger instances"
        
        for port in "${active_ports[@]}"; do
            echo -e "${CYAN}  Port $port:${NC}"
            check_chrome_debugger "$port"
            check_nginx_proxy "$port"
        done
    fi
    echo
    
    # System resources
    echo -e "${CYAN}System Resources:${NC}"
    check_system_resources
    echo
    
    # Log analysis
    echo -e "${CYAN}Log Analysis:${NC}"
    check_logs
    echo
    
    # Overall status
    echo -e "${CYAN}Overall Status:${NC}"
    case "$OVERALL_STATUS" in
        "healthy")
            log "SUCCESS" "System is healthy"
            ;;
        "degraded")
            log "WARNING" "System is degraded ($ISSUES_FOUND issues found)"
            ;;
        "unhealthy")
            log "FAILURE" "System is unhealthy ($ISSUES_FOUND critical issues found)"
            ;;
    esac
    
    echo
    log "INFO" "Health check completed at $(date)"
    log "INFO" "Full health log: $HEALTH_LOG"
}

# Quick status check
quick_status() {
    echo "Chrome Debugger Proxy Quick Status:"
    echo "==================================="
    
    # nginx
    if systemctl is-active nginx >/dev/null 2>&1; then
        echo -e "nginx:     ${GREEN}${SUCCESS} Running${NC}"
    else
        echo -e "nginx:     ${RED}${FAILURE} Not running${NC}"
    fi
    
    # Active Chrome instances
    local active_ports
    active_ports=($(discover_chrome_ports))
    echo -e "Chrome:    ${GREEN}${SUCCESS} ${#active_ports[@]} instances${NC}"
    
    if [[ ${#active_ports[@]} -gt 0 ]]; then
        echo "  Ports: ${active_ports[*]}"
    fi
    
    # System load
    local load_avg
    load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    echo -e "Load:      ${GREEN}${INFO} $load_avg${NC}"
    
    echo
}

# Continuous monitoring mode
monitor_continuous() {
    local interval="${1:-30}"
    
    log "INFO" "Starting continuous monitoring (interval: ${interval}s)"
    log "INFO" "Press Ctrl+C to stop"
    
    while true; do
        clear
        quick_status
        echo "Next check in ${interval} seconds... (Ctrl+C to stop)"
        sleep "$interval"
    done
}

# Usage information
usage() {
    cat << EOF
Chrome Debugger Proxy Health Check Script

Usage: $0 [COMMAND] [OPTIONS]

Commands:
    check               Run full health check (default)
    quick               Run quick status check
    monitor [INTERVAL]  Continuous monitoring (default interval: 30s)
    logs               Show recent log entries
    
Options:
    -h, --help         Show this help message
    -v, --verbose      Enable verbose output
    -q, --quiet        Suppress non-critical output
    
Examples:
    $0                 # Run full health check
    $0 quick           # Quick status check
    $0 monitor 60      # Monitor every 60 seconds
    $0 logs            # Show recent logs

EOF
}

# Show recent logs
show_logs() {
    echo "=== Recent nginx Error Logs ==="
    if [[ -f "$LOG_DIR/error.log" ]]; then
        tail -n 20 "$LOG_DIR/error.log" | head -n 20
    else
        echo "No nginx error log found"
    fi
    
    echo -e "\n=== Recent Chrome Logs ==="
    if [[ -d "$CHROME_LOG_DIR" ]]; then
        for log_file in "$CHROME_LOG_DIR"/chrome-*.log; do
            if [[ -f "$log_file" ]]; then
                echo "--- $(basename "$log_file") ---"
                tail -n 10 "$log_file"
                echo
            fi
        done
    else
        echo "No Chrome logs found"
    fi
    
    echo -e "\n=== Recent Health Check Logs ==="
    if [[ -f "$HEALTH_LOG" ]]; then
        tail -n 20 "$HEALTH_LOG"
    else
        echo "No health check log found"
    fi
}

# Main function
main() {
    local command="${1:-check}"
    
    # Ensure log directory exists
    mkdir -p "$(dirname "$HEALTH_LOG")"
    
    case "$command" in
        check)
            local active_ports
            active_ports=($(discover_chrome_ports))
            generate_health_report "${active_ports[@]}"
            
            # Return appropriate exit code
            case "$OVERALL_STATUS" in
                "healthy") exit 0 ;;
                "degraded") exit 1 ;;
                "unhealthy") exit 2 ;;
            esac
            ;;
        quick)
            quick_status
            ;;
        monitor)
            local interval="${2:-30}"
            monitor_continuous "$interval"
            ;;
        logs)
            show_logs
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            echo "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

# Handle script interruption
trap 'echo -e "\n${YELLOW}Health check interrupted${NC}"; exit 130' INT TERM

# Check for required commands
for cmd in systemctl curl nginx; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "FAILURE" "Required command not found: $cmd"
        exit 1
    fi
done

# Run main function with all arguments
main "$@"