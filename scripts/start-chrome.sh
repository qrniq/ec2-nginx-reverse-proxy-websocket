#!/bin/bash

# Chrome Debugger Launcher Script
# Starts Chrome with remote debugging enabled on specified port range
# Includes port management, process monitoring, and error handling

set -euo pipefail

# Configuration
DEFAULT_PORT_RANGE_START=48000
DEFAULT_PORT_RANGE_END=49000
CHROME_DATA_DIR="/tmp/chrome-debug-data"
CHROME_LOG_DIR="/var/log/chrome-debug"
PID_DIR="/var/run/chrome-debug"
MAX_INSTANCES=50
CHROME_BINARY=""

# Logging setup
mkdir -p "$CHROME_LOG_DIR" "$PID_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$CHROME_LOG_DIR/launcher.log"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2 | tee -a "$CHROME_LOG_DIR/launcher.log"
}

# Find Chrome binary
find_chrome_binary() {
    local chrome_paths=(
        "/usr/bin/google-chrome"
        "/usr/bin/google-chrome-stable"
        "/usr/bin/chromium"
        "/usr/bin/chromium-browser"
        "/opt/google/chrome/google-chrome"
    )
    
    for path in "${chrome_paths[@]}"; do
        if [[ -x "$path" ]]; then
            CHROME_BINARY="$path"
            log "Found Chrome binary at: $CHROME_BINARY"
            return 0
        fi
    done
    
    error "Chrome binary not found. Please install Google Chrome or Chromium."
    exit 1
}

# Check if port is available
is_port_available() {
    local port=$1
    ! ss -tuln | grep -q ":$port "
}

# Find next available port in range
find_available_port() {
    local start_port=${1:-$DEFAULT_PORT_RANGE_START}
    local end_port=${2:-$DEFAULT_PORT_RANGE_END}
    
    for ((port=start_port; port<=end_port; port++)); do
        if is_port_available "$port"; then
            echo "$port"
            return 0
        fi
    done
    
    error "No available ports in range $start_port-$end_port"
    return 1
}

# Start Chrome instance
start_chrome() {
    local port=$1
    local additional_args=("${@:2}")
    
    log "Starting Chrome with remote debugging on port $port"
    
    # Create unique data directory for this instance
    local data_dir="$CHROME_DATA_DIR/chrome-$port"
    mkdir -p "$data_dir"
    
    # Chrome arguments for debugging
    local chrome_args=(
        "--remote-debugging-port=$port"
        "--remote-debugging-address=0.0.0.0"
        "--user-data-dir=$data_dir"
        "--headless=new"
        "--no-sandbox"
        "--disable-gpu"
        "--disable-dev-shm-usage"
        "--disable-extensions"
        "--disable-plugins"
        "--disable-images"
        "--disable-javascript"
        "--virtual-time-budget=5000"
        "--run-all-compositor-stages-before-draw"
        "--disable-background-timer-throttling"
        "--disable-renderer-backgrounding"
        "--disable-backgrounding-occluded-windows"
        "--disable-features=TranslateUI,VizDisplayCompositor"
        "--enable-logging"
        "--log-level=0"
        "--no-first-run"
        "--no-default-browser-check"
        "--disable-default-apps"
    )
    
    # Add any additional arguments
    chrome_args+=("${additional_args[@]}")
    
    # Start Chrome in background
    local log_file="$CHROME_LOG_DIR/chrome-$port.log"
    local pid_file="$PID_DIR/chrome-$port.pid"
    
    log "Chrome command: $CHROME_BINARY ${chrome_args[*]}"
    
    nohup "$CHROME_BINARY" "${chrome_args[@]}" > "$log_file" 2>&1 &
    local chrome_pid=$!
    
    echo "$chrome_pid" > "$pid_file"
    log "Chrome started with PID $chrome_pid on port $port"
    
    # Wait for Chrome to start and verify it's accessible
    local max_attempts=30
    local attempt=0
    
    while ((attempt < max_attempts)); do
        if curl -s "http://localhost:$port/json/version" > /dev/null 2>&1; then
            log "Chrome debugger is ready on port $port"
            echo "$port"
            return 0
        fi
        
        # Check if process is still running
        if ! kill -0 "$chrome_pid" 2>/dev/null; then
            error "Chrome process died unexpectedly (PID: $chrome_pid)"
            return 1
        fi
        
        ((attempt++))
        sleep 1
    done
    
    error "Chrome failed to start properly on port $port after $max_attempts attempts"
    kill "$chrome_pid" 2>/dev/null || true
    rm -f "$pid_file"
    return 1
}

# Stop Chrome instance
stop_chrome() {
    local port=$1
    local pid_file="$PID_DIR/chrome-$port.pid"
    
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        
        if kill -0 "$pid" 2>/dev/null; then
            log "Stopping Chrome on port $port (PID: $pid)"
            kill -TERM "$pid"
            
            # Wait for graceful shutdown
            local attempts=10
            while ((attempts-- > 0)) && kill -0 "$pid" 2>/dev/null; do
                sleep 1
            done
            
            # Force kill if still running
            if kill -0 "$pid" 2>/dev/null; then
                log "Force killing Chrome on port $port"
                kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
        
        rm -f "$pid_file"
        log "Chrome on port $port stopped"
    else
        log "No PID file found for port $port"
    fi
    
    # Cleanup data directory
    local data_dir="$CHROME_DATA_DIR/chrome-$port"
    if [[ -d "$data_dir" ]]; then
        rm -rf "$data_dir"
        log "Cleaned up data directory for port $port"
    fi
}

# Stop all Chrome instances
stop_all_chrome() {
    log "Stopping all Chrome debug instances"
    
    for pid_file in "$PID_DIR"/chrome-*.pid; do
        if [[ -f "$pid_file" ]]; then
            local port
            port=$(basename "$pid_file" .pid | cut -d'-' -f2)
            stop_chrome "$port"
        fi
    done
    
    # Kill any remaining Chrome processes
    pkill -f "remote-debugging-port=" || true
    
    # Cleanup directories
    rm -rf "$CHROME_DATA_DIR"
    rm -f "$PID_DIR"/chrome-*.pid
    
    log "All Chrome instances stopped"
}

# List running Chrome instances
list_chrome() {
    echo "Running Chrome debug instances:"
    echo "PORT    PID     STATUS"
    echo "------------------------"
    
    for pid_file in "$PID_DIR"/chrome-*.pid; do
        if [[ -f "$pid_file" ]]; then
            local port
            port=$(basename "$pid_file" .pid | cut -d'-' -f2)
            local pid
            pid=$(cat "$pid_file")
            
            if kill -0 "$pid" 2>/dev/null; then
                if curl -s "http://localhost:$port/json/version" > /dev/null 2>&1; then
                    echo "$port    $pid     READY"
                else
                    echo "$port    $pid     STARTING"
                fi
            else
                echo "$port    $pid     DEAD"
                rm -f "$pid_file"
            fi
        fi
    done
}

# Health check for Chrome instance
health_check() {
    local port=$1
    
    if curl -s "http://localhost:$port/json/version" > /dev/null 2>&1; then
        local version
        version=$(curl -s "http://localhost:$port/json/version" | jq -r '.Browser // "Unknown"' 2>/dev/null || echo "Unknown")
        echo "Chrome on port $port is healthy (Version: $version)"
        return 0
    else
        echo "Chrome on port $port is not responding"
        return 1
    fi
}

# Generate nginx configuration for a port
generate_nginx_config() {
    local port=$1
    local template_file="/root/repo/nginx/templates/proxy-template.conf"
    local output_file="/etc/nginx/conf.d/chrome-proxy-$port.conf"
    
    if [[ -f "$template_file" ]]; then
        sed "s/{{PORT}}/$port/g" "$template_file" > "$output_file"
        log "Generated nginx config for port $port: $output_file"
        
        # Test nginx configuration
        if nginx -t 2>/dev/null; then
            systemctl reload nginx || service nginx reload
            log "Reloaded nginx configuration"
        else
            error "nginx configuration test failed"
            rm -f "$output_file"
            return 1
        fi
    else
        error "Template file not found: $template_file"
        return 1
    fi
}

# Usage information
usage() {
    cat << EOF
Chrome Debugger Launcher Script

Usage: $0 [COMMAND] [OPTIONS]

Commands:
    start [PORT]              Start Chrome on specific port or find available port
    stop PORT                 Stop Chrome instance on specified port
    stop-all                  Stop all Chrome instances
    list                      List running Chrome instances
    health PORT               Check health of Chrome instance on port
    generate-config PORT      Generate nginx config for port

Options:
    -h, --help               Show this help message
    -r, --range START-END    Port range for auto-discovery (default: 48000-49000)
    -d, --debug              Enable debug output
    
Examples:
    $0 start                 # Start Chrome on first available port
    $0 start 48333           # Start Chrome on port 48333
    $0 stop 48333            # Stop Chrome on port 48333
    $0 health 48333          # Check if Chrome on port 48333 is healthy
    $0 list                  # List all running instances

EOF
}

# Main function
main() {
    local command="${1:-}"
    
    case "$command" in
        start)
            find_chrome_binary
            local port="${2:-}"
            
            if [[ -z "$port" ]]; then
                port=$(find_available_port)
            elif ! is_port_available "$port"; then
                error "Port $port is already in use"
                exit 1
            fi
            
            if start_chrome "$port" "${@:3}"; then
                generate_nginx_config "$port"
                echo "Chrome started successfully on port $port"
                echo "Access debugger at: http://localhost:$port"
            else
                exit 1
            fi
            ;;
        stop)
            local port="${2:-}"
            if [[ -z "$port" ]]; then
                error "Port number required for stop command"
                usage
                exit 1
            fi
            
            stop_chrome "$port"
            
            # Remove nginx config
            local nginx_config="/etc/nginx/conf.d/chrome-proxy-$port.conf"
            if [[ -f "$nginx_config" ]]; then
                rm -f "$nginx_config"
                nginx -t && (systemctl reload nginx || service nginx reload)
                log "Removed nginx config for port $port"
            fi
            ;;
        stop-all)
            stop_all_chrome
            
            # Remove all nginx configs
            rm -f /etc/nginx/conf.d/chrome-proxy-*.conf
            nginx -t && (systemctl reload nginx || service nginx reload)
            log "Removed all nginx configs"
            ;;
        list)
            list_chrome
            ;;
        health)
            local port="${2:-}"
            if [[ -z "$port" ]]; then
                error "Port number required for health command"
                usage
                exit 1
            fi
            
            health_check "$port"
            ;;
        generate-config)
            local port="${2:-}"
            if [[ -z "$port" ]]; then
                error "Port number required for generate-config command"
                usage
                exit 1
            fi
            
            generate_nginx_config "$port"
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"