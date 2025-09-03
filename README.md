# Chrome Debugger nginx Reverse Proxy

A comprehensive nginx reverse proxy solution for Chrome Remote Interface debugging, designed for AWS EC2 deployment with WebSocket support across port range 48000-49000.

## Overview

This solution provides a robust nginx reverse proxy that enables external access to Chrome debugger instances through WebSocket connections. It's optimized for high-volume debugging scenarios and includes comprehensive monitoring, testing, and management tools.

### Key Features

- **nginx Reverse Proxy**: WebSocket-enabled proxy for Chrome Remote Interface
- **Dynamic Port Management**: Supports Chrome debugger ports 48000-49000
- **High Performance**: Optimized for concurrent WebSocket connections
- **Comprehensive Monitoring**: Health checks, logging, and performance metrics
- **Easy Management**: Systemd services with automated startup/shutdown
- **Testing Suite**: Node.js-based testing and load testing tools
- **Security Focused**: Proper security headers, rate limiting, and access controls

## Architecture

```
Internet → nginx (Reverse Proxy) → Chrome Debugger Instances
          ↓                        ↓
      WebSocket                DevTools Protocol
      Connections             (ports 48000-49000)
```

## Quick Start

### Prerequisites

- AWS EC2 instance (Ubuntu 20.04+ or CentOS 8+)
- Root access
- Google Chrome or Chromium browser
- Node.js (for testing)

### Installation

1. **Clone and Setup**
   ```bash
   git clone <repository-url>
   cd ec2-nginx-reverse-proxy-websocket
   ```

2. **Install nginx and Configure**
   ```bash
   sudo ./scripts/setup-nginx.sh
   ```

3. **Install System Services**
   ```bash
   sudo ./systemd/install-services.sh
   ```

4. **Start Services**
   ```bash
   sudo chrome-proxy-service start
   ```

5. **Verify Installation**
   ```bash
   chrome-proxy-service status
   ./scripts/health-check.sh
   ```

### Testing

```bash
# Install test dependencies
cd test
npm install

# Run connection tests
npm test

# Run load tests
npm run test:load

# Run integration tests
npm run test:integration
```

## Configuration

### nginx Configuration

The main nginx configuration is located in `nginx/nginx.conf` with Chrome-specific proxy settings in `nginx/conf.d/chrome-proxy.conf`.

**Key Configuration Features:**
- WebSocket upgrade headers
- Connection timeout optimization
- Rate limiting and security headers
- Custom error pages
- CORS support for browser access

### Chrome Launcher

Chrome instances are managed via `scripts/start-chrome.sh`:

```bash
# Start Chrome on first available port
./scripts/start-chrome.sh start

# Start Chrome on specific port
./scripts/start-chrome.sh start 48333

# Stop Chrome instance
./scripts/start-chrome.sh stop 48333

# List running instances
./scripts/start-chrome.sh list
```

### Port Management

The system automatically manages ports in the range 48000-49000:
- Finds available ports
- Generates nginx configurations
- Handles port conflicts
- Cleans up on shutdown

## Service Management

### Systemd Services

Three main services work together:

1. **chrome-debugger.service** - Manages Chrome instances
2. **nginx-proxy.service** - nginx reverse proxy
3. **chrome-proxy-manager.service** - Orchestrates both services

### Management Commands

```bash
# Service control
chrome-proxy-service start|stop|restart|status

# Health monitoring
./scripts/health-check.sh

# View logs
chrome-proxy-service logs [service-name]
```

## API Endpoints

Once running, the following endpoints are available:

### DevTools Protocol Endpoints
- `http://localhost:PORT/json/version` - Chrome version info
- `http://localhost:PORT/json/list` - Available debug targets
- `http://localhost:PORT/json` - DevTools protocol info

### WebSocket Endpoints
- `ws://localhost:PORT/devtools/page/{pageId}` - Page debugging
- Direct WebSocket URLs from `/json/list` response

### Health Monitoring
- `http://localhost:PORT/health` - Health check endpoint
- `http://localhost/health` - nginx health check

## Testing and Validation

### Connection Testing

```bash
# Basic connection test
./test/connection-test.js

# Load testing with custom parameters
./test/load-test.js --port 48333 --connections 20 --messages 100
```

### Health Monitoring

```bash
# Full health check
./scripts/health-check.sh

# Quick status
./scripts/health-check.sh quick

# Continuous monitoring
./scripts/health-check.sh monitor 30
```

### Integration Testing

```bash
# Full integration test suite
./test/integration-test.sh
```

## Performance Optimization

### nginx Optimizations

- **Worker Processes**: Auto-scaled based on CPU cores
- **Connection Limits**: 8192 connections per worker
- **Buffer Sizes**: Optimized for WebSocket traffic
- **Keepalive**: Persistent connections for better performance

### Chrome Optimizations

- **Headless Mode**: Reduced resource usage
- **Disabled Features**: Non-essential features disabled
- **Resource Limits**: Memory and process limits via systemd

### System Limits

```bash
# File descriptor limits
ulimit -n 65536

# Connection limits configured in nginx
worker_rlimit_nofile 65535
worker_connections 8192
```

## Security Considerations

### Network Security
- Rate limiting (10 requests/second per IP)
- Connection limits (10 concurrent per IP)
- CORS headers for controlled browser access
- Custom error pages (no information disclosure)

### Process Security
- Dedicated `chrome` user for Chrome processes
- systemd security features (NoNewPrivileges, ProtectSystem)
- Private temporary directories
- Resource limits

### Firewall Configuration
The setup script automatically configures firewall rules:
- Port 80/443 for nginx
- Ports 48000-49000 for Chrome debugger

## Troubleshooting

### Common Issues

**Chrome won't start:**
```bash
# Check Chrome process
ps aux | grep chrome

# Check logs
tail -f /var/log/chrome-debug/chrome-*.log

# Manual start for debugging
google-chrome --remote-debugging-port=48333 --headless
```

**nginx proxy errors:**
```bash
# Test nginx configuration
nginx -t

# Check nginx logs
tail -f /var/log/nginx/error.log

# Verify port accessibility
curl http://localhost:48333/json/version
```

**WebSocket connection failures:**
```bash
# Check WebSocket upgrade headers
curl -H "Upgrade: websocket" -H "Connection: upgrade" http://localhost:48333/

# Test with WebSocket client
node test/connection-test.js
```

### Log Locations

- nginx logs: `/var/log/nginx/`
- Chrome logs: `/var/log/chrome-debug/`
- Health check logs: `/var/log/chrome-proxy-health.log`
- Service logs: `journalctl -u chrome-debugger`

### Health Monitoring

The system includes automated health monitoring:
- Systemd timer checks every 5 minutes
- Automatic service restart on health check failure
- Comprehensive status reporting

## File Structure

```
/
├── nginx/
│   ├── nginx.conf                    # Main nginx configuration
│   ├── conf.d/
│   │   └── chrome-proxy.conf         # Chrome proxy configuration
│   └── templates/
│       └── proxy-template.conf       # Template for dynamic ports
├── scripts/
│   ├── start-chrome.sh               # Chrome launcher and manager
│   ├── setup-nginx.sh                # nginx installation and setup
│   └── health-check.sh               # Health monitoring script
├── test/
│   ├── package.json                  # Node.js test dependencies
│   ├── connection-test.js            # Connection validation tests
│   ├── load-test.js                  # Performance load testing
│   └── integration-test.sh           # Full integration test suite
├── systemd/
│   ├── chrome-debugger.service       # Chrome service configuration
│   ├── nginx-proxy.service           # nginx service configuration
│   ├── chrome-proxy-manager.service  # Manager service
│   └── install-services.sh           # Service installation script
├── docs/
│   ├── ARCHITECTURE.md               # System architecture documentation
│   ├── TROUBLESHOOTING.md            # Detailed troubleshooting guide
│   └── API.md                        # API documentation
└── README.md                         # This file
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## License

MIT License - see LICENSE file for details.

## Support

For issues and support:
1. Check the troubleshooting guide in `docs/TROUBLESHOOTING.md`
2. Run health checks: `./scripts/health-check.sh`
3. Review logs for error details
4. Open an issue with full error details and system information

---

**Terragon Labs** - High-performance debugging infrastructure for modern web applications.