#!/bin/bash

# nginx Setup Script for Chrome Debugger Proxy
# Installs and configures nginx with Chrome debugger proxy settings
# Supports Ubuntu/Debian and CentOS/RHEL systems

set -euo pipefail

# Configuration
NGINX_CONF_DIR="/etc/nginx"
NGINX_SITES_DIR="$NGINX_CONF_DIR/sites-available"
NGINX_CONF_D_DIR="$NGINX_CONF_DIR/conf.d"
LOG_DIR="/var/log/nginx"
PROJECT_DIR="~/ec2-nginx-reverse-proxy-websocket"
BACKUP_DIR="/tmp/nginx-backup-$(date +%Y%m%d-%H%M%S)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*${NC}"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*${NC}" >&2
}

# Detect operating system
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        error "Cannot detect operating system"
        exit 1
    fi
    
    log "Detected OS: $OS $VERSION"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Install nginx based on OS
install_nginx() {
    log "Installing nginx..."
    
    case "$OS" in
        ubuntu|debian)
            apt-get update
            apt-get install -y nginx curl jq
            ;;
        centos|rhel|fedora)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y nginx curl jq
            else
                yum install -y nginx curl jq
            fi
            ;;
        *)
            error "Unsupported operating system: $OS"
            exit 1
            ;;
    esac
    
    # Verify installation
    if ! command -v nginx >/dev/null 2>&1; then
        error "nginx installation failed"
        exit 1
    fi
    
    log "nginx installed successfully: $(nginx -v 2>&1)"
}

# Backup existing nginx configuration
backup_nginx_config() {
    log "Backing up existing nginx configuration to $BACKUP_DIR"
    
    mkdir -p "$BACKUP_DIR"
    
    if [[ -f "$NGINX_CONF_DIR/nginx.conf" ]]; then
        cp "$NGINX_CONF_DIR/nginx.conf" "$BACKUP_DIR/"
        log "Backed up nginx.conf"
    fi
    
    if [[ -d "$NGINX_CONF_D_DIR" ]]; then
        cp -r "$NGINX_CONF_D_DIR" "$BACKUP_DIR/"
        log "Backed up conf.d directory"
    fi
    
    if [[ -d "$NGINX_SITES_DIR" ]]; then
        cp -r "$NGINX_SITES_DIR" "$BACKUP_DIR/"
        log "Backed up sites-available directory"
    fi
}

# Setup nginx configuration
setup_nginx_config() {
    log "Setting up nginx configuration for Chrome debugger proxy..."
    
    # Copy main nginx configuration
    if [[ -f "$PROJECT_DIR/nginx/nginx.conf" ]]; then
        cp "$PROJECT_DIR/nginx/nginx.conf" "$NGINX_CONF_DIR/"
        log "Copied main nginx.conf"
    else
        error "nginx.conf not found in $PROJECT_DIR/nginx/"
        exit 1
    fi
    
    # Ensure conf.d directory exists
    mkdir -p "$NGINX_CONF_D_DIR"
    
    # Copy Chrome proxy configuration
    if [[ -f "$PROJECT_DIR/nginx/conf.d/chrome-proxy.conf" ]]; then
        cp "$PROJECT_DIR/nginx/conf.d/chrome-proxy.conf" "$NGINX_CONF_D_DIR/"
        log "Copied chrome-proxy.conf"
    else
        error "chrome-proxy.conf not found in $PROJECT_DIR/nginx/conf.d/"
        exit 1
    fi
    
    # Create templates directory
    mkdir -p "$NGINX_CONF_DIR/templates"
    
    if [[ -f "$PROJECT_DIR/nginx/templates/proxy-template.conf" ]]; then
        cp "$PROJECT_DIR/nginx/templates/proxy-template.conf" "$NGINX_CONF_DIR/templates/"
        log "Copied proxy-template.conf"
    fi
}

# Create necessary directories and set permissions
setup_directories() {
    log "Setting up directories and permissions..."
    
    # Create log directories
    mkdir -p "$LOG_DIR"
    
    # Create nginx user if it doesn't exist
    if ! id -u nginx >/dev/null 2>&1; then
        case "$OS" in
            ubuntu|debian)
                adduser --system --group --no-create-home --disabled-login nginx
                ;;
            centos|rhel|fedora)
                adduser --system --shell /bin/false --home-dir /var/cache/nginx nginx
                ;;
        esac
        log "Created nginx user"
    fi
    
    # Set proper ownership and permissions
    chown -R nginx:nginx "$LOG_DIR"
    chmod 755 "$LOG_DIR"
    
    # Set SELinux context on RHEL/CentOS systems
    if command -v setsebool >/dev/null 2>&1; then
        log "Configuring SELinux for nginx..."
        setsebool -P httpd_can_network_connect 1 || warn "Failed to set SELinux policy for network connections"
        setsebool -P httpd_can_network_relay 1 || warn "Failed to set SELinux policy for network relay"
    fi
}

# Test nginx configuration
test_nginx_config() {
    log "Testing nginx configuration..."
    
    if nginx -t; then
        log "nginx configuration test passed"
    else
        error "nginx configuration test failed"
        log "Restoring backup configuration..."
        restore_backup
        exit 1
    fi
}

# Restore backup configuration
restore_backup() {
    if [[ -d "$BACKUP_DIR" ]]; then
        log "Restoring nginx configuration from backup..."
        
        if [[ -f "$BACKUP_DIR/nginx.conf" ]]; then
            cp "$BACKUP_DIR/nginx.conf" "$NGINX_CONF_DIR/"
        fi
        
        if [[ -d "$BACKUP_DIR/conf.d" ]]; then
            rm -rf "$NGINX_CONF_D_DIR"
            cp -r "$BACKUP_DIR/conf.d" "$NGINX_CONF_DIR/"
        fi
        
        log "Configuration restored from backup"
    fi
}

# Configure firewall
configure_firewall() {
    log "Configuring firewall rules..."
    
    # Ubuntu/Debian with ufw
    if command -v ufw >/dev/null 2>&1; then
        log "Configuring ufw firewall..."
        ufw allow 80/tcp || warn "Failed to allow HTTP port"
        ufw allow 443/tcp || warn "Failed to allow HTTPS port"
        
        # Allow Chrome debugger port range
        ufw allow 48000:49000/tcp || warn "Failed to allow Chrome debugger port range"
        
        # Check if ufw is active before trying to reload
        if ufw status | grep -q "Status: active"; then
            ufw reload || warn "Failed to reload ufw"
        fi
    fi
    
    # CentOS/RHEL with firewalld
    if command -v firewalld >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        log "Configuring firewalld..."
        firewall-cmd --permanent --add-service=http || warn "Failed to allow HTTP service"
        firewall-cmd --permanent --add-service=https || warn "Failed to allow HTTPS service"
        
        # Allow Chrome debugger port range
        firewall-cmd --permanent --add-port=48000-49000/tcp || warn "Failed to allow Chrome debugger port range"
        
        firewall-cmd --reload || warn "Failed to reload firewalld"
    fi
    
    # Legacy iptables (if no modern firewall is found)
    if ! command -v ufw >/dev/null 2>&1 && ! systemctl is-active firewalld >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1; then
        log "Configuring iptables..."
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT || warn "Failed to allow HTTP port"
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT || warn "Failed to allow HTTPS port"
        iptables -I INPUT -p tcp --dport 48000:49000 -j ACCEPT || warn "Failed to allow Chrome debugger port range"
        
        # Save iptables rules
        if command -v iptables-save >/dev/null 2>&1; then
            case "$OS" in
                ubuntu|debian)
                    iptables-save > /etc/iptables/rules.v4 2>/dev/null || warn "Failed to save iptables rules"
                    ;;
                centos|rhel)
                    iptables-save > /etc/sysconfig/iptables 2>/dev/null || warn "Failed to save iptables rules"
                    ;;
            esac
        fi
    fi
}

# Start and enable nginx service
start_nginx() {
    log "Starting and enabling nginx service..."
    
    systemctl enable nginx
    systemctl start nginx
    
    if systemctl is-active nginx >/dev/null 2>&1; then
        log "nginx service started successfully"
    else
        error "Failed to start nginx service"
        systemctl status nginx
        exit 1
    fi
}

# Create helper scripts
create_helper_scripts() {
    log "Creating helper scripts..."
    
    # Create nginx reload script
    cat > /usr/local/bin/reload-nginx-chrome-proxy << 'EOF'
#!/bin/bash
# Reload nginx configuration for Chrome proxy

echo "Testing nginx configuration..."
if nginx -t; then
    echo "Reloading nginx..."
    systemctl reload nginx
    echo "nginx reloaded successfully"
else
    echo "nginx configuration test failed!"
    exit 1
fi
EOF
    
    chmod +x /usr/local/bin/reload-nginx-chrome-proxy
    log "Created reload-nginx-chrome-proxy script"
    
    # Create nginx status script
    cat > /usr/local/bin/nginx-chrome-proxy-status << 'EOF'
#!/bin/bash
# Check nginx Chrome proxy status

echo "=== nginx Service Status ==="
systemctl status nginx --no-pager

echo -e "\n=== nginx Configuration Test ==="
nginx -t

echo -e "\n=== Active Chrome Proxy Configurations ==="
ls -la /etc/nginx/conf.d/chrome-proxy*.conf 2>/dev/null || echo "No Chrome proxy configurations found"

echo -e "\n=== nginx Process Information ==="
ps aux | grep nginx | grep -v grep

echo -e "\n=== nginx Listening Ports ==="
ss -tuln | grep nginx || ss -tuln | grep :80 || ss -tuln | grep :443 || echo "nginx not listening on standard ports"

echo -e "\n=== Recent nginx Error Logs ==="
tail -n 10 /var/log/nginx/error.log 2>/dev/null || echo "No error logs found"
EOF
    
    chmod +x /usr/local/bin/nginx-chrome-proxy-status
    log "Created nginx-chrome-proxy-status script"
}

# Verify installation
verify_installation() {
    log "Verifying nginx Chrome proxy installation..."
    
    # Check nginx is running
    if ! systemctl is-active nginx >/dev/null 2>&1; then
        error "nginx service is not running"
        return 1
    fi
    
    # Check nginx is listening on port 80
    if ! ss -tuln | grep -q ":80 "; then
        error "nginx is not listening on port 80"
        return 1
    fi
    
    # Test health endpoint
    if curl -s http://localhost/health | grep -q "healthy"; then
        log "Health endpoint is working"
    else
        warn "Health endpoint may not be working correctly"
    fi
    
    log "Installation verification completed successfully"
}

# Main function
main() {
    log "Starting nginx Chrome debugger proxy setup..."
    
    check_root
    detect_os
    
    # Install nginx if not present
    if ! command -v nginx >/dev/null 2>&1; then
        install_nginx
    else
        log "nginx is already installed: $(nginx -v 2>&1)"
    fi
    
    backup_nginx_config
    setup_nginx_config
    setup_directories
    test_nginx_config
    configure_firewall
    create_helper_scripts
    start_nginx
    verify_installation
    
    log "nginx Chrome debugger proxy setup completed successfully!"
    log ""
    log "Next steps:"
    log "1. Start Chrome with debugging: $PROJECT_DIR/scripts/start-chrome.sh start"
    log "2. Test the proxy: $PROJECT_DIR/test/connection-test.js"
    log "3. Check status: nginx-chrome-proxy-status"
    log "4. Reload config: reload-nginx-chrome-proxy"
    log ""
    log "Configuration backup saved to: $BACKUP_DIR"
}

# Handle script interruption
trap 'error "Script interrupted"; exit 1' INT TERM

# Parse command line arguments
case "${1:-}" in
    --help|-h)
        cat << EOF
nginx Chrome Debugger Proxy Setup Script

Usage: $0 [OPTIONS]

Options:
    --help, -h          Show this help message
    --backup-only       Only backup existing configuration
    --restore           Restore from backup (requires backup directory)
    --test-only         Only test configuration, don't install

Examples:
    sudo $0                    # Full setup
    sudo $0 --backup-only      # Backup only
    sudo $0 --test-only        # Test configuration only

EOF
        exit 0
        ;;
    --backup-only)
        check_root
        backup_nginx_config
        log "Backup completed: $BACKUP_DIR"
        exit 0
        ;;
    --restore)
        RESTORE_DIR="${2:-}"
        if [[ -z "$RESTORE_DIR" || ! -d "$RESTORE_DIR" ]]; then
            error "Restore directory required and must exist"
            exit 1
        fi
        check_root
        BACKUP_DIR="$RESTORE_DIR"
        restore_backup
        test_nginx_config
        systemctl reload nginx
        log "Configuration restored and nginx reloaded"
        exit 0
        ;;
    --test-only)
        test_nginx_config
        log "Configuration test completed"
        exit 0
        ;;
    "")
        # Default: run full setup
        main
        ;;
    *)
        error "Unknown option: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac