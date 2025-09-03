#!/usr/bin/env node

/**
 * Chrome Remote Interface Connection Test
 * Tests Chrome debugger nginx proxy WebSocket connections
 * Validates DevTools protocol communication through nginx reverse proxy
 */

const CDP = require('chrome-remote-interface');
const WebSocket = require('ws');
const fetch = require('node-fetch');

// Test configuration
const TEST_CONFIG = {
    host: 'localhost',
    portRange: {
        start: 48000,
        end: 49000
    },
    timeout: 10000,
    maxRetries: 3
};

class ChromeProxyTester {
    constructor(config = TEST_CONFIG) {
        this.config = config;
        this.results = {
            passed: 0,
            failed: 0,
            errors: []
        };
    }

    log(message, level = 'INFO') {
        const timestamp = new Date().toISOString();
        console.log(`[${timestamp}] [${level}] ${message}`);
    }

    error(message, error = null) {
        this.log(message, 'ERROR');
        if (error) {
            console.error(error);
        }
        this.results.errors.push({ message, error: error?.message || error });
    }

    async testHttpEndpoint(port, endpoint) {
        const url = `http://${this.config.host}:${port}${endpoint}`;
        
        try {
            const response = await fetch(url, {
                timeout: this.config.timeout,
                headers: {
                    'User-Agent': 'Chrome-Proxy-Test/1.0'
                }
            });

            if (!response.ok) {
                throw new Error(`HTTP ${response.status}: ${response.statusText}`);
            }

            const data = await response.json();
            return { success: true, data };
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    async testWebSocketConnection(port, wsUrl) {
        return new Promise((resolve) => {
            const timeout = setTimeout(() => {
                resolve({ success: false, error: 'Connection timeout' });
            }, this.config.timeout);

            try {
                const ws = new WebSocket(wsUrl);
                
                ws.on('open', () => {
                    clearTimeout(timeout);
                    
                    // Send a simple DevTools Protocol message
                    const message = JSON.stringify({
                        id: 1,
                        method: 'Runtime.evaluate',
                        params: {
                            expression: '1 + 1'
                        }
                    });
                    
                    ws.send(message);
                });

                ws.on('message', (data) => {
                    try {
                        const response = JSON.parse(data.toString());
                        
                        if (response.id === 1 && response.result?.result?.value === 2) {
                            ws.close();
                            resolve({ success: true, data: response });
                        } else {
                            ws.close();
                            resolve({ success: false, error: 'Unexpected response', data: response });
                        }
                    } catch (error) {
                        ws.close();
                        resolve({ success: false, error: 'Invalid JSON response' });
                    }
                });

                ws.on('error', (error) => {
                    clearTimeout(timeout);
                    resolve({ success: false, error: error.message });
                });

                ws.on('close', (code, reason) => {
                    if (code !== 1000) {
                        clearTimeout(timeout);
                        resolve({ success: false, error: `WebSocket closed with code ${code}: ${reason}` });
                    }
                });

            } catch (error) {
                clearTimeout(timeout);
                resolve({ success: false, error: error.message });
            }
        });
    }

    async testChromeRemoteInterface(port) {
        try {
            // Connect using Chrome Remote Interface
            const client = await CDP({ 
                host: this.config.host, 
                port: port,
                timeout: this.config.timeout 
            });
            
            const { Runtime } = client;
            
            // Enable Runtime domain
            await Runtime.enable();
            
            // Test simple expression evaluation
            const result = await Runtime.evaluate({
                expression: 'navigator.userAgent'
            });
            
            await client.close();
            
            if (result.result.type === 'string') {
                return { success: true, userAgent: result.result.value };
            } else {
                return { success: false, error: 'Unexpected result type' };
            }
            
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    async discoverActivePorts() {
        const activePorts = [];
        
        this.log(`Scanning ports ${this.config.portRange.start}-${this.config.portRange.end} for active Chrome instances...`);
        
        for (let port = this.config.portRange.start; port <= this.config.portRange.end; port++) {
            const result = await this.testHttpEndpoint(port, '/json/version');
            
            if (result.success) {
                activePorts.push(port);
                this.log(`Found active Chrome debugger on port ${port}`);
            }
        }
        
        return activePorts;
    }

    async runTestsForPort(port) {
        this.log(`\n=== Testing Chrome debugger proxy on port ${port} ===`);
        
        const portResults = {
            port,
            tests: {},
            overall: true
        };

        // Test 1: Version endpoint
        this.log(`Testing /json/version endpoint on port ${port}...`);
        const versionTest = await this.testHttpEndpoint(port, '/json/version');
        portResults.tests.version = versionTest;
        
        if (versionTest.success) {
            this.log(`✓ Version endpoint working: ${versionTest.data.Browser}`);
            this.results.passed++;
        } else {
            this.error(`✗ Version endpoint failed: ${versionTest.error}`);
            this.results.failed++;
            portResults.overall = false;
        }

        // Test 2: List endpoint
        this.log(`Testing /json/list endpoint on port ${port}...`);
        const listTest = await this.testHttpEndpoint(port, '/json/list');
        portResults.tests.list = listTest;
        
        if (listTest.success) {
            this.log(`✓ List endpoint working: Found ${listTest.data.length} targets`);
            this.results.passed++;
        } else {
            this.error(`✗ List endpoint failed: ${listTest.error}`);
            this.results.failed++;
            portResults.overall = false;
        }

        // Test 3: WebSocket connection (if we have targets)
        if (listTest.success && listTest.data.length > 0) {
            const target = listTest.data.find(t => t.webSocketDebuggerUrl) || listTest.data[0];
            
            if (target.webSocketDebuggerUrl) {
                this.log(`Testing WebSocket connection on port ${port}...`);
                
                // Replace the WebSocket URL to go through nginx proxy
                const proxyWsUrl = target.webSocketDebuggerUrl.replace(
                    `ws://localhost:${port}`,
                    `ws://${this.config.host}:${port}`
                );
                
                const wsTest = await this.testWebSocketConnection(port, proxyWsUrl);
                portResults.tests.websocket = wsTest;
                
                if (wsTest.success) {
                    this.log(`✓ WebSocket connection working: Expression evaluated successfully`);
                    this.results.passed++;
                } else {
                    this.error(`✗ WebSocket connection failed: ${wsTest.error}`);
                    this.results.failed++;
                    portResults.overall = false;
                }
            }
        }

        // Test 4: Chrome Remote Interface library
        this.log(`Testing Chrome Remote Interface library connection on port ${port}...`);
        const cdpTest = await this.testChromeRemoteInterface(port);
        portResults.tests.cdp = cdpTest;
        
        if (cdpTest.success) {
            this.log(`✓ Chrome Remote Interface working: Connected to ${cdpTest.userAgent}`);
            this.results.passed++;
        } else {
            this.error(`✗ Chrome Remote Interface failed: ${cdpTest.error}`);
            this.results.failed++;
            portResults.overall = false;
        }

        // Test 5: Health endpoint
        this.log(`Testing /health endpoint on port ${port}...`);
        const healthTest = await this.testHttpEndpoint(port, '/health');
        portResults.tests.health = healthTest;
        
        if (healthTest.success) {
            this.log(`✓ Health endpoint working`);
            this.results.passed++;
        } else {
            this.log(`! Health endpoint not available (this is optional)`);
        }

        return portResults;
    }

    async runAllTests() {
        this.log('Chrome Debugger Nginx Proxy Connection Test Suite');
        this.log('='.repeat(50));
        
        const activePorts = await this.discoverActivePorts();
        
        if (activePorts.length === 0) {
            this.error('No active Chrome debugger instances found in port range');
            this.log('Please start Chrome with: ./scripts/start-chrome.sh start');
            return false;
        }

        this.log(`Found ${activePorts.length} active Chrome debugger instances`);
        
        const allResults = [];
        
        for (const port of activePorts) {
            const portResult = await this.runTestsForPort(port);
            allResults.push(portResult);
        }

        // Summary
        this.log('\n' + '='.repeat(50));
        this.log('TEST SUMMARY');
        this.log('='.repeat(50));
        
        allResults.forEach(result => {
            const status = result.overall ? '✓ PASS' : '✗ FAIL';
            this.log(`Port ${result.port}: ${status}`);
        });
        
        this.log(`\nTotal tests: ${this.results.passed + this.results.failed}`);
        this.log(`Passed: ${this.results.passed}`);
        this.log(`Failed: ${this.results.failed}`);
        
        if (this.results.errors.length > 0) {
            this.log('\nErrors encountered:');
            this.results.errors.forEach((error, index) => {
                this.log(`${index + 1}. ${error.message}`);
            });
        }
        
        const success = this.results.failed === 0 && this.results.passed > 0;
        
        if (success) {
            this.log('\n🎉 All tests passed! Chrome debugger nginx proxy is working correctly.');
        } else {
            this.log('\n❌ Some tests failed. Please check the nginx and Chrome configurations.');
        }
        
        return success;
    }
}

// Example usage and test execution
async function main() {
    const tester = new ChromeProxyTester();
    
    try {
        const success = await tester.runAllTests();
        process.exit(success ? 0 : 1);
    } catch (error) {
        console.error('Fatal error running tests:', error);
        process.exit(1);
    }
}

// Run tests if this script is executed directly
if (require.main === module) {
    main();
}

module.exports = ChromeProxyTester;