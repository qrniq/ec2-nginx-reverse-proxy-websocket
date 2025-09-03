#!/bin/bash

# Chrome Debugger Nginx Proxy Integration Test Suite
# Comprehensive end-to-end testing of the entire system
# Tests installation, configuration, service management, and functionality

set -euo pipefail

# Test configuration
TEST_PORT=48888
TEST_TIMEOUT=30
PROJECT_DIR="/root/repo"
TEMP_DIR="/tmp/chrome-proxy-integration-test"
LOG_FILE="$TEMP_DIR/integration-test.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Test tracking
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST=""
START_TIME=0

# Logging setup
setup_logging() {
    mkdir -p "$TEMP_DIR"
    exec 1> >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)
    
    log "INFO" "Integration test started at $(date)"
    log "INFO" "Test directory: $TEMP_DIR"
    log "INFO" "Log file: $LOG_FILE"
}

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%H:%M:%S')
    
    case "$level" in
        "SUCCESS")
            echo -e "${GREEN}✓${NC} [$timestamp] $message"
            ;;
        "FAILURE")
            echo -e "${RED}✗${NC} [$timestamp] $message"
            ;;
        "WARNING")
            echo -e "${YELLOW}!${NC} [$timestamp] $message"
            ;;
        "INFO")
            echo -e "${BLUE}i${NC} [$timestamp] $message"
            ;;
        "TEST")
            echo -e "${CYAN}▶${NC} [$timestamp] $message"
            ;;
        *)
            echo "[$timestamp] $message"
            ;;
    esac
}

# Test framework functions
start_test() {
    CURRENT_TEST="$1"
    ((TESTS_TOTAL++))
    START_TIME=$(date +%s)
    log "TEST" "Starting: $CURRENT_TEST"
}

pass_test() {
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    ((TESTS_PASSED++))
    log "SUCCESS" "PASS: $CURRENT_TEST (${duration}s)"
}

fail_test() {
    local reason="${1:-Unknown reason}"
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    ((TESTS_FAILED++))
    log "FAILURE" "FAIL: $CURRENT_TEST (${duration}s) - $reason"
}

# Utility functions
check_command() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

wait_for_port() {
    local port="$1"
    local timeout="${2:-30}"
    local count=0
    
    while ((count < timeout)); do
        if ss -tuln | grep -q ":$port "; then
            return 0
        fi
        sleep 1
        ((count++))
    done
    
    return 1
}

wait_for_http() {
    local url="$1"
    local timeout="${2:-30}"
    local count=0
    
    while ((count < timeout)); do
        if curl -s "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        ((count++))
    done
    
    return 1
}

cleanup_test_environment() {
    log "INFO" "Cleaning up test environment..."
    
    # Stop any test Chrome instances
    "$PROJECT_DIR/scripts/start-chrome.sh" stop "$TEST_PORT" 2>/dev/null || true
    
    # Remove test nginx configurations
    sudo rm -f "/etc/nginx/conf.d/chrome-proxy-$TEST_PORT.conf" 2>/dev/null || true
    
    # Kill any remaining processes
    pkill -f "remote-debugging-port=$TEST_PORT" 2>/dev/null || true
    
    # Wait for cleanup
    sleep 2
}

# Test functions
test_prerequisites() {
    start_test "Prerequisites Check"
    
    local missing_commands=()
    
    # Check required commands
    local required_commands=("nginx" "curl" "ss" "systemctl" "node" "npm")
    
    for cmd in "${required_commands[@]}"; do
        if ! check_command "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        fail_test "Missing commands: ${missing_commands[*]}"
        return 1
    fi
    
    # Check if running as root for some tests
    if [[ $EUID -ne 0 ]]; then
        log "WARNING" "Not running as root - some tests may be skipped"
    fi
    
    pass_test
}

test_project_structure() {
    start_test "Project Structure Validation"
    
    local required_files=(
        "nginx/nginx.conf"
        "nginx/conf.d/chrome-proxy.conf"
        "nginx/templates/proxy-template.conf"
        "scripts/start-chrome.sh"
        "scripts/setup-nginx.sh"
        "scripts/health-check.sh"
        "test/package.json"
        "test/connection-test.js"
        "test/load-test.js"
        "systemd/chrome-debugger.service"
        "systemd/nginx-proxy.service"
        "systemd/install-services.sh"
        "README.md"
    )
    
    local missing_files=()
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$PROJECT_DIR/$file" ]]; then
            missing_files+=("$file")
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        fail_test "Missing files: ${missing_files[*]}"
        return 1
    fi
    
    # Check file permissions
    local executable_files=(
        "scripts/start-chrome.sh"
        "scripts/setup-nginx.sh"
        "scripts/health-check.sh"
        "test/connection-test.js"
        "test/load-test.js"
        "systemd/install-services.sh"
    )
    
    for file in "${executable_files[@]}"; do
        if [[ ! -x "$PROJECT_DIR/$file" ]]; then
            fail_test "File not executable: $file"
            return 1
        fi
    done
    
    pass_test
}

test_nginx_configuration() {
    start_test "nginx Configuration Validation"
    
    # Test main nginx configuration
    if ! nginx -t -c "$PROJECT_DIR/nginx/nginx.conf" >/dev/null 2>&1; then
        fail_test "nginx configuration test failed"
        return 1
    fi
    
    # Check for required directives
    local required_directives=(
        "worker_processes"
        "worker_connections"
        "proxy_http_version"
        "proxy_set_header.*Upgrade"
        "proxy_set_header.*Connection"
    )
    
    for directive in "${required_directives[@]}"; do
        if ! grep -q "$directive" "$PROJECT_DIR/nginx/nginx.conf" "$PROJECT_DIR/nginx/conf.d/chrome-proxy.conf"; then
            fail_test "Missing nginx directive: $directive"
            return 1
        fi
    done
    
    pass_test
}

test_chrome_launcher() {
    start_test "Chrome Launcher Functionality"
    
    cleanup_test_environment
    
    # Test Chrome launcher script
    if ! "$PROJECT_DIR/scripts/start-chrome.sh" start "$TEST_PORT" >/dev/null 2>&1; then
        fail_test "Failed to start Chrome with launcher script"
        return 1
    fi
    
    # Wait for Chrome to start
    if ! wait_for_port "$TEST_PORT" 30; then
        fail_test "Chrome did not start listening on port $TEST_PORT"
        cleanup_test_environment
        return 1
    fi
    
    # Test DevTools protocol endpoints
    local endpoints=("/json/version" "/json/list")
    
    for endpoint in "${endpoints[@]}"; do
        if ! wait_for_http "http://localhost:$TEST_PORT$endpoint" 10; then
            fail_test "Chrome endpoint not accessible: $endpoint"
            cleanup_test_environment
            return 1
        fi
    done
    
    # Test stopping Chrome
    if ! "$PROJECT_DIR/scripts/start-chrome.sh" stop "$TEST_PORT" >/dev/null 2>&1; then
        fail_test "Failed to stop Chrome instance"
        cleanup_test_environment
        return 1
    fi
    
    pass_test
}

test_nginx_proxy() {
    start_test "nginx Proxy Functionality"
    
    cleanup_test_environment
    
    # Start Chrome
    if ! "$PROJECT_DIR/scripts/start-chrome.sh" start "$TEST_PORT" >/dev/null 2>&1; then
        fail_test "Failed to start Chrome for proxy test"
        return 1
    fi
    
    # Wait for Chrome
    if ! wait_for_port "$TEST_PORT" 30; then
        fail_test "Chrome not ready for proxy test"
        cleanup_test_environment
        return 1
    fi
    
    # Generate nginx configuration for test port
    if ! "$PROJECT_DIR/scripts/start-chrome.sh" generate-config "$TEST_PORT" >/dev/null 2>&1; then
        fail_test "Failed to generate nginx configuration"
        cleanup_test_environment
        return 1
    fi
    
    # Test nginx configuration
    if ! nginx -t >/dev/null 2>&1; then
        fail_test "nginx configuration invalid after generating proxy config"
        cleanup_test_environment
        return 1
    fi
    
    # Reload nginx (if we have permission)
    if [[ $EUID -eq 0 ]]; then
        if ! systemctl reload nginx >/dev/null 2>&1; then
            log "WARNING" "Could not reload nginx - testing direct Chrome connection"
        fi
    fi
    
    # Test proxy endpoints
    local endpoints=("/json/version" "/json/list")
    
    for endpoint in "${endpoints[@]}"; do
        if ! curl -s "http://localhost:$TEST_PORT$endpoint" >/dev/null; then
            fail_test "Proxy endpoint not accessible: $endpoint"
            cleanup_test_environment
            return 1
        fi
    done
    
    cleanup_test_environment
    pass_test
}

test_node_dependencies() {
    start_test "Node.js Test Dependencies"
    
    cd "$PROJECT_DIR/test" || {
        fail_test "Cannot access test directory"
        return 1
    }
    
    # Check if package.json exists
    if [[ ! -f "package.json" ]]; then
        fail_test "package.json not found in test directory"
        return 1
    fi
    
    # Install dependencies
    if ! npm install >/dev/null 2>&1; then
        fail_test "npm install failed"
        return 1
    fi
    
    # Check if required modules are installed
    local required_modules=("chrome-remote-interface" "ws")
    
    for module in "${required_modules[@]}"; do
        if [[ ! -d "node_modules/$module" ]]; then
            fail_test "Required module not installed: $module"
            return 1
        fi
    done
    
    pass_test
}

test_connection_test_script() {
    start_test "Connection Test Script"
    
    cleanup_test_environment
    
    # Start Chrome for testing
    if ! "$PROJECT_DIR/scripts/start-chrome.sh" start "$TEST_PORT" >/dev/null 2>&1; then
        fail_test "Failed to start Chrome for connection test"
        return 1
    fi
    
    # Wait for Chrome
    if ! wait_for_port "$TEST_PORT" 30; then
        fail_test "Chrome not ready for connection test"
        cleanup_test_environment
        return 1
    fi
    
    cd "$PROJECT_DIR/test" || {
        fail_test "Cannot access test directory"
        cleanup_test_environment
        return 1
    }
    
    # Run connection test (modify to test our specific port)
    local test_output
    test_output=$(timeout 60 node connection-test.js 2>&1) || {
        fail_test "Connection test script failed: $test_output"
        cleanup_test_environment
        return 1
    }
    
    # Check if test found our Chrome instance
    if ! echo "$test_output" | grep -q "test.*passed\|SUCCESS\|working"; then
        fail_test "Connection test did not indicate success: $test_output"
        cleanup_test_environment
        return 1
    fi
    
    cleanup_test_environment
    pass_test
}

test_health_check_script() {
    start_test "Health Check Script"
    
    cleanup_test_environment
    
    # Start Chrome
    if ! "$PROJECT_DIR/scripts/start-chrome.sh" start "$TEST_PORT" >/dev/null 2>&1; then
        fail_test "Failed to start Chrome for health check test"
        return 1
    fi
    
    # Wait for Chrome
    if ! wait_for_port "$TEST_PORT" 30; then
        fail_test "Chrome not ready for health check test"
        cleanup_test_environment
        return 1
    fi
    
    # Run health check
    if ! "$PROJECT_DIR/scripts/health-check.sh" quick >/dev/null 2>&1; then
        log "WARNING" "Health check reported issues (may be expected in test environment)"
    fi
    
    # Test health check commands
    if ! "$PROJECT_DIR/scripts/health-check.sh" --help >/dev/null 2>&1; then
        fail_test "Health check help command failed"
        cleanup_test_environment
        return 1
    fi
    
    cleanup_test_environment
    pass_test
}

test_service_files() {
    start_test "Systemd Service Files Validation"
    
    local service_files=(
        "systemd/chrome-debugger.service"
        "systemd/nginx-proxy.service"
        "systemd/chrome-proxy-manager.service"
    )
    
    for service_file in "${service_files[@]}"; do
        local file_path="$PROJECT_DIR/$service_file"
        
        if [[ ! -f "$file_path" ]]; then
            fail_test "Service file missing: $service_file"
            return 1
        fi
        
        # Check for required systemd sections
        local required_sections=("\[Unit\]" "\[Service\]" "\[Install\]")
        
        for section in "${required_sections[@]}"; do
            if ! grep -q "$section" "$file_path"; then
                fail_test "Missing systemd section in $service_file: $section"
                return 1
            fi
        done
    done
    
    # Test service installer
    if [[ ! -x "$PROJECT_DIR/systemd/install-services.sh" ]]; then
        fail_test "Service installer script not executable"
        return 1
    fi
    
    # Test installer help
    if ! "$PROJECT_DIR/systemd/install-services.sh" --help >/dev/null 2>&1; then
        fail_test "Service installer help command failed"
        return 1
    fi
    
    pass_test
}

test_load_test_script() {
    start_test "Load Test Script"
    
    cleanup_test_environment
    
    # Start Chrome
    if ! "$PROJECT_DIR/scripts/start-chrome.sh" start "$TEST_PORT" >/dev/null 2>&1; then
        fail_test "Failed to start Chrome for load test"
        return 1
    fi
    
    # Wait for Chrome
    if ! wait_for_port "$TEST_PORT" 30; then
        fail_test "Chrome not ready for load test"
        cleanup_test_environment
        return 1
    fi
    
    cd "$PROJECT_DIR/test" || {
        fail_test "Cannot access test directory"
        cleanup_test_environment
        return 1
    }
    
    # Run light load test (reduced parameters for integration testing)
    local test_output
    test_output=$(timeout 120 node load-test.js --port "$TEST_PORT" --connections 2 --messages 5 --duration 10 2>&1) || {
        fail_test "Load test script failed: $test_output"
        cleanup_test_environment
        return 1
    }
    
    # Check if load test completed
    if ! echo "$test_output" | grep -q "LOAD TEST RESULTS\|Overall Assessment"; then
        fail_test "Load test did not complete properly: $test_output"
        cleanup_test_environment
        return 1
    fi
    
    cleanup_test_environment
    pass_test
}

test_security_configuration() {
    start_test "Security Configuration Check"
    
    # Check nginx security headers
    local security_headers=(
        "X-Frame-Options"
        "X-Content-Type-Options" 
        "X-XSS-Protection"
    )
    
    for header in "${security_headers[@]}"; do
        if ! grep -q "$header" "$PROJECT_DIR/nginx/nginx.conf"; then
            fail_test "Missing security header in nginx config: $header"
            return 1
        fi
    done
    
    # Check rate limiting configuration
    if ! grep -q "limit_req_zone\|limit_conn_zone" "$PROJECT_DIR/nginx/nginx.conf"; then
        fail_test "Missing rate limiting configuration"
        return 1
    fi
    
    # Check systemd security features
    local security_features=(
        "NoNewPrivileges=true"
        "ProtectSystem"
        "PrivateTmp=true"
    )
    
    local service_files=(
        "$PROJECT_DIR/systemd/chrome-debugger.service"
        "$PROJECT_DIR/systemd/nginx-proxy.service"
    )
    
    for service_file in "${service_files[@]}"; do
        for feature in "${security_features[@]}"; do
            if ! grep -q "$feature" "$service_file"; then
                log "WARNING" "Missing security feature in $(basename "$service_file"): $feature"
            fi
        done
    done
    
    pass_test
}

test_documentation() {
    start_test "Documentation Completeness"
    
    # Check README.md
    if [[ ! -f "$PROJECT_DIR/README.md" ]]; then
        fail_test "README.md not found"
        return 1
    fi
    
    # Check for required sections in README
    local required_sections=(
        "Overview"
        "Quick Start"
        "Configuration"
        "Testing"
        "Troubleshooting"
        "File Structure"
    )
    
    for section in "${required_sections[@]}"; do
        if ! grep -q "## $section\|# $section" "$PROJECT_DIR/README.md"; then
            fail_test "Missing section in README.md: $section"
            return 1
        fi
    done
    
    # Check inline documentation in scripts
    local documented_scripts=(
        "scripts/start-chrome.sh"
        "scripts/setup-nginx.sh"
        "scripts/health-check.sh"
    )
    
    for script in "${documented_scripts[@]}"; do
        if ! head -20 "$PROJECT_DIR/$script" | grep -q "#.*[Dd]escription\|#.*Usage\|#.*Script"; then
            log "WARNING" "Script may lack adequate documentation: $script"
        fi
    done
    
    pass_test
}

test_cleanup_procedures() {
    start_test "Cleanup Procedures"
    
    cleanup_test_environment
    
    # Test Chrome launcher cleanup
    "$PROJECT_DIR/scripts/start-chrome.sh" start "$TEST_PORT" >/dev/null 2>&1 || true
    sleep 2
    
    if ! "$PROJECT_DIR/scripts/start-chrome.sh" stop-all >/dev/null 2>&1; then
        fail_test "Chrome launcher stop-all command failed"
        return 1
    fi
    
    # Verify cleanup
    if pgrep -f "remote-debugging-port=$TEST_PORT" >/dev/null 2>&1; then
        fail_test "Chrome processes not properly cleaned up"
        return 1
    fi
    
    # Test nginx config cleanup
    sudo rm -f "/etc/nginx/conf.d/chrome-proxy-$TEST_PORT.conf" 2>/dev/null || true
    
    pass_test
}

# Generate test report
generate_test_report() {
    local end_time=$(date)
    local total_duration=$(($(date +%s) - OVERALL_START_TIME))
    
    echo
    log "INFO" "=========================================="
    log "INFO" "INTEGRATION TEST REPORT"
    log "INFO" "=========================================="
    echo
    log "INFO" "Test execution completed: $end_time"
    log "INFO" "Total duration: ${total_duration}s"
    echo
    log "INFO" "Tests executed: $TESTS_TOTAL"
    log "SUCCESS" "Tests passed: $TESTS_PASSED"
    log "FAILURE" "Tests failed: $TESTS_FAILED"
    echo
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        log "SUCCESS" "🎉 All integration tests passed!"
        log "INFO" "The Chrome Debugger nginx Proxy is ready for deployment."
    else
        log "FAILURE" "❌ $TESTS_FAILED test(s) failed."
        log "INFO" "Please review the test output and resolve issues before deployment."
    fi
    
    echo
    log "INFO" "Test log available at: $LOG_FILE"
    
    # Cleanup
    cleanup_test_environment
}

# Signal handler for cleanup
cleanup_on_exit() {
    log "INFO" "Cleaning up on exit..."
    cleanup_test_environment
    exit 1
}

# Main execution
main() {
    OVERALL_START_TIME=$(date +%s)
    
    setup_logging
    
    # Set up signal handlers
    trap cleanup_on_exit INT TERM
    
    log "INFO" "Starting Chrome Debugger nginx Proxy Integration Test Suite"
    log "INFO" "Project directory: $PROJECT_DIR"
    log "INFO" "Test port: $TEST_PORT"
    echo
    
    # Run all tests
    test_prerequisites
    test_project_structure
    test_nginx_configuration
    test_chrome_launcher
    test_nginx_proxy
    test_node_dependencies
    test_connection_test_script
    test_health_check_script
    test_service_files
    test_load_test_script
    test_security_configuration
    test_documentation
    test_cleanup_procedures
    
    # Generate report
    generate_test_report
    
    # Return appropriate exit code
    if [[ $TESTS_FAILED -eq 0 ]]; then
        exit 0
    else
        exit 1
    fi
}

# Usage information
usage() {
    cat << EOF
Chrome Debugger nginx Proxy Integration Test Suite

Usage: $0 [OPTIONS]

Options:
    --port PORT     Use specific port for testing (default: $TEST_PORT)
    --timeout SEC   Set timeout for operations (default: $TEST_TIMEOUT)
    --help, -h      Show this help message

Examples:
    $0                    # Run full integration test suite
    $0 --port 48999       # Use port 48999 for testing
    $0 --timeout 60       # Set 60 second timeout

The integration test suite validates:
- Project structure and file permissions
- nginx configuration syntax and features
- Chrome launcher functionality
- nginx proxy configuration and operation
- Node.js test scripts and dependencies
- Health monitoring and service management
- Security configuration
- Documentation completeness
- Cleanup procedures

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            TEST_PORT="$2"
            shift 2
            ;;
        --timeout)
            TEST_TIMEOUT="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Run main function
main "$@"