#!/bin/bash

# Install systemd services for Chrome Debugger Proxy
# Sets up service files and creates necessary user accounts

set -euo pipefail

# Configuration
SYSTEMD_DIR="/etc/systemd/system"
PROJECT_DIR="/root/repo"
LOG_DIR="/var/log/chrome-debug"
RUN_DIR="/var/run/chrome-debug"
DATA_DIR="/tmp/chrome-debug-data"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] $*${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARNING: $*${NC}"
}

error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] ERROR: $*${NC}" >&2
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Create chrome user for running Chrome processes
create_chrome_user() {
    if ! id -u chrome >/dev/null 2>&1; then
        log "Creating chrome user..."
        
        # Create system user for Chrome
        useradd --system --shell /bin/false --home-dir "$DATA_DIR" \
                --no-create-home --user-group chrome
        
        log "Created chrome user"
    else
        log "Chrome user already exists"
    fi
}

# Setup directories and permissions
setup_directories() {
    log "Setting up directories..."
    
    # Create required directories
    mkdir -p "$LOG_DIR" "$RUN_DIR" "$DATA_DIR"
    
    # Set ownership and permissions
    chown -R chrome:chrome "$LOG_DIR" "$RUN_DIR" "$DATA_DIR"
    chmod 755 "$LOG_DIR" "$RUN_DIR" "$DATA_DIR"
    
    # Ensure nginx can read proxy configurations
    if [[ -d "/etc/nginx/conf.d" ]]; then
        chmod 755 /etc/nginx/conf.d
    fi
    
    log "Directories setup completed"
}

# Install systemd service files
install_service_files() {
    log "Installing systemd service files..."
    
    local service_files=(
        "chrome-debugger.service"
        "nginx-proxy.service"
        "chrome-proxy-manager.service"
    )
    
    for service_file in "${service_files[@]}"; do
        local source_file="$PROJECT_DIR/systemd/$service_file"
        local target_file="$SYSTEMD_DIR/$service_file"
        
        if [[ -f "$source_file" ]]; then
            cp "$source_file" "$target_file"
            chmod 644 "$target_file"
            log "Installed $service_file"
        else
            error "Source file not found: $source_file"
            exit 1
        fi
    done
}

# Reload systemd and enable services
enable_services() {
    log "Reloading systemd daemon..."
    systemctl daemon-reload
    
    log "Enabling services..."
    
    # Enable individual services
    systemctl enable chrome-debugger.service
    systemctl enable nginx-proxy.service
    systemctl enable chrome-proxy-manager.service
    
    log "Services enabled"
}

# Validate service files
validate_services() {
    log "Validating service files..."
    
    local services=(
        "chrome-debugger"
        "nginx-proxy"
        "chrome-proxy-manager"
    )
    
    for service in "${services[@]}"; do
        if systemctl status "$service" >/dev/null 2>&1 || [[ $? -eq 3 ]]; then
            log "Service $service configuration is valid"
        else
            error "Service $service configuration is invalid"
            systemctl status "$service" --no-pager
            return 1
        fi
    done
}

# Create service management scripts
create_management_scripts() {
    log "Creating service management scripts..."
    
    # Main control script
    cat > /usr/local/bin/chrome-proxy-service << 'EOF'
#!/bin/bash
# Chrome Debugger Proxy Service Controller

SERVICES=("chrome-debugger" "nginx-proxy" "chrome-proxy-manager")

case "$1" in
    start)
        echo "Starting Chrome Debugger Proxy services..."
        systemctl start chrome-proxy-manager
        ;;
    stop)
        echo "Stopping Chrome Debugger Proxy services..."
        systemctl stop chrome-proxy-manager
        systemctl stop nginx-proxy
        systemctl stop chrome-debugger
        ;;
    restart)
        echo "Restarting Chrome Debugger Proxy services..."
        $0 stop
        sleep 2
        $0 start
        ;;
    reload)
        echo "Reloading Chrome Debugger Proxy services..."
        systemctl reload chrome-proxy-manager
        ;;
    status)
        echo "Chrome Debugger Proxy Service Status:"
        echo "======================================"
        for service in "${SERVICES[@]}"; do
            echo -n "$service: "
            if systemctl is-active "$service" >/dev/null 2>&1; then
                echo -e "\033[0;32mActive\033[0m"
            elif systemctl is-enabled "$service" >/dev/null 2>&1; then
                echo -e "\033[0;33mEnabled (Inactive)\033[0m"
            else
                echo -e "\033[0;31mDisabled\033[0m"
            fi
        done
        echo
        /root/repo/scripts/health-check.sh quick
        ;;
    logs)
        service="${2:-chrome-debugger}"
        echo "Showing logs for $service..."
        journalctl -u "$service" -f --no-pager
        ;;
    enable)
        echo "Enabling Chrome Debugger Proxy services..."
        for service in "${SERVICES[@]}"; do
            systemctl enable "$service"
        done
        ;;
    disable)
        echo "Disabling Chrome Debugger Proxy services..."
        for service in "${SERVICES[@]}"; do
            systemctl disable "$service"
        done
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|reload|status|logs [service]|enable|disable}"
        echo
        echo "Available services: ${SERVICES[*]}"
        exit 1
        ;;
esac
EOF
    
    chmod +x /usr/local/bin/chrome-proxy-service
    log "Created chrome-proxy-service control script"
    
    # Health monitoring script for systemd
    cat > /usr/local/bin/chrome-proxy-health-monitor << 'EOF'
#!/bin/bash
# Health monitor for Chrome Debugger Proxy services

HEALTH_CHECK="/root/repo/scripts/health-check.sh"
LOG_FILE="/var/log/chrome-proxy-health-monitor.log"

if [[ -x "$HEALTH_CHECK" ]]; then
    if ! "$HEALTH_CHECK" check >/dev/null 2>&1; then
        echo "[$(date)] Health check failed, attempting service restart" >> "$LOG_FILE"
        systemctl restart chrome-proxy-manager
        
        # Wait and recheck
        sleep 10
        if "$HEALTH_CHECK" check >/dev/null 2>&1; then
            echo "[$(date)] Service restart successful" >> "$LOG_FILE"
        else
            echo "[$(date)] Service restart failed, manual intervention required" >> "$LOG_FILE"
        fi
    fi
else
    echo "[$(date)] Health check script not found: $HEALTH_CHECK" >> "$LOG_FILE"
fi
EOF
    
    chmod +x /usr/local/bin/chrome-proxy-health-monitor
    log "Created chrome-proxy-health-monitor script"
}

# Setup log rotation
setup_logrotate() {
    log "Setting up log rotation..."
    
    cat > /etc/logrotate.d/chrome-debugger-proxy << 'EOF'
/var/log/chrome-debug/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 chrome chrome
    postrotate
        systemctl reload chrome-debugger >/dev/null 2>&1 || true
    endscript
}

/var/log/chrome-proxy-health*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
EOF
    
    log "Log rotation configured"
}

# Setup systemd timer for health monitoring
setup_health_timer() {
    log "Setting up health monitoring timer..."
    
    # Create timer unit
    cat > "$SYSTEMD_DIR/chrome-proxy-health.timer" << 'EOF'
[Unit]
Description=Chrome Debugger Proxy Health Check Timer
Requires=chrome-proxy-health.service

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    # Create service unit for the timer
    cat > "$SYSTEMD_DIR/chrome-proxy-health.service" << 'EOF'
[Unit]
Description=Chrome Debugger Proxy Health Check
After=chrome-proxy-manager.service
Wants=chrome-proxy-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/chrome-proxy-health-monitor
User=root
StandardOutput=journal
StandardError=journal
EOF
    
    # Enable and start the timer
    systemctl daemon-reload
    systemctl enable chrome-proxy-health.timer
    systemctl start chrome-proxy-health.timer
    
    log "Health monitoring timer configured and started"
}

# Print final instructions
print_instructions() {
    log "Installation completed successfully!"
    echo
    echo "=== Chrome Debugger Proxy Service Management ==="
    echo
    echo "Control services:"
    echo "  chrome-proxy-service start    # Start all services"
    echo "  chrome-proxy-service stop     # Stop all services"
    echo "  chrome-proxy-service status   # Check status"
    echo "  chrome-proxy-service logs     # View logs"
    echo
    echo "Individual service management:"
    echo "  systemctl start chrome-debugger"
    echo "  systemctl start nginx-proxy"
    echo "  systemctl start chrome-proxy-manager"
    echo
    echo "Health monitoring:"
    echo "  /root/repo/scripts/health-check.sh"
    echo "  systemctl status chrome-proxy-health.timer"
    echo
    echo "Next steps:"
    echo "1. Start services: chrome-proxy-service start"
    echo "2. Check status: chrome-proxy-service status"
    echo "3. Run tests: cd /root/repo/test && npm install && npm test"
    echo
}

# Uninstall services (for cleanup)
uninstall_services() {
    log "Uninstalling Chrome Debugger Proxy services..."
    
    # Stop and disable services
    systemctl stop chrome-proxy-manager nginx-proxy chrome-debugger chrome-proxy-health.timer 2>/dev/null || true
    systemctl disable chrome-proxy-manager nginx-proxy chrome-debugger chrome-proxy-health.timer 2>/dev/null || true
    
    # Remove service files
    rm -f "$SYSTEMD_DIR"/chrome-debugger.service
    rm -f "$SYSTEMD_DIR"/nginx-proxy.service
    rm -f "$SYSTEMD_DIR"/chrome-proxy-manager.service
    rm -f "$SYSTEMD_DIR"/chrome-proxy-health.service
    rm -f "$SYSTEMD_DIR"/chrome-proxy-health.timer
    
    # Remove management scripts
    rm -f /usr/local/bin/chrome-proxy-service
    rm -f /usr/local/bin/chrome-proxy-health-monitor
    
    # Remove logrotate configuration
    rm -f /etc/logrotate.d/chrome-debugger-proxy
    
    # Reload systemd
    systemctl daemon-reload
    
    log "Services uninstalled"
}

# Main function
main() {
    local action="${1:-install}"
    
    case "$action" in
        install)
            check_root
            create_chrome_user
            setup_directories
            install_service_files
            enable_services
            validate_services
            create_management_scripts
            setup_logrotate
            setup_health_timer
            print_instructions
            ;;
        uninstall)
            check_root
            uninstall_services
            ;;
        --help|-h)
            echo "Usage: $0 [install|uninstall]"
            echo
            echo "install    - Install and configure systemd services (default)"
            echo "uninstall  - Remove systemd services and configuration"
            exit 0
            ;;
        *)
            error "Unknown action: $action"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
}

main "$@"