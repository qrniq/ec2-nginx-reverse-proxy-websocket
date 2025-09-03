#!/usr/bin/env node

/**
 * Chrome Debugger Nginx Proxy Load Test
 * Tests performance and scalability of WebSocket connections through nginx
 * Simulates multiple concurrent connections and measures response times
 */

const WebSocket = require('ws');
const fetch = require('node-fetch');
const { performance } = require('perf_hooks');

class ChromeProxyLoadTester {
    constructor(config = {}) {
        this.config = {
            host: 'localhost',
            port: 48333,
            concurrentConnections: 10,
            messagesPerConnection: 50,
            testDuration: 30000, // 30 seconds
            rampUpTime: 5000, // 5 seconds
            ...config
        };
        
        this.stats = {
            connectionsStarted: 0,
            connectionsCompleted: 0,
            connectionsFailed: 0,
            messagesSucceeded: 0,
            messagesFailed: 0,
            responseTimes: [],
            connectionTimes: [],
            errors: []
        };
        
        this.activeConnections = new Set();
        this.startTime = 0;
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
        this.stats.errors.push({ message, error: error?.message || error });
    }

    async discoverWebSocketUrl() {
        try {
            const response = await fetch(`http://${this.config.host}:${this.config.port}/json/list`);
            const targets = await response.json();
            
            const target = targets.find(t => t.webSocketDebuggerUrl) || targets[0];
            
            if (target && target.webSocketDebuggerUrl) {
                return target.webSocketDebuggerUrl.replace(
                    `ws://localhost:${this.config.port}`,
                    `ws://${this.config.host}:${this.config.port}`
                );
            } else {
                throw new Error('No WebSocket debugger URL found');
            }
        } catch (error) {
            throw new Error(`Failed to discover WebSocket URL: ${error.message}`);
        }
    }

    async createTestConnection(connectionId, wsUrl) {
        return new Promise((resolve) => {
            const connectionStart = performance.now();
            let messagesCompleted = 0;
            let messageId = 0;
            const connectionStats = {
                id: connectionId,
                messagesSucceeded: 0,
                messagesFailed: 0,
                responseTimes: [],
                connectionTime: 0,
                error: null
            };

            try {
                const ws = new WebSocket(wsUrl);
                this.activeConnections.add(ws);

                ws.on('open', () => {
                    connectionStats.connectionTime = performance.now() - connectionStart;
                    this.stats.connectionTimes.push(connectionStats.connectionTime);
                    this.stats.connectionsStarted++;
                    
                    this.log(`Connection ${connectionId} established (${connectionStats.connectionTime.toFixed(2)}ms)`);
                    
                    // Start sending messages
                    this.sendTestMessages(ws, connectionStats, resolve);
                });

                ws.on('message', (data) => {
                    try {
                        const response = JSON.parse(data.toString());
                        
                        if (response.id && response.id <= this.config.messagesPerConnection) {
                            const messageEnd = performance.now();
                            const responseTime = messageEnd - response.sentTime;
                            
                            connectionStats.responseTimes.push(responseTime);
                            connectionStats.messagesSucceeded++;
                            this.stats.messagesSucceeded++;
                            
                            messagesCompleted++;
                            
                            if (messagesCompleted >= this.config.messagesPerConnection) {
                                ws.close();
                            }
                        }
                    } catch (error) {
                        connectionStats.messagesFailed++;
                        this.stats.messagesFailed++;
                        this.error(`Connection ${connectionId}: Failed to parse message`, error);
                    }
                });

                ws.on('error', (error) => {
                    connectionStats.error = error.message;
                    this.stats.connectionsFailed++;
                    this.error(`Connection ${connectionId}: WebSocket error`, error);
                    resolve(connectionStats);
                });

                ws.on('close', (code, reason) => {
                    this.activeConnections.delete(ws);
                    this.stats.connectionsCompleted++;
                    
                    if (code === 1000) {
                        this.log(`Connection ${connectionId} completed successfully`);
                    } else {
                        this.log(`Connection ${connectionId} closed with code ${code}: ${reason}`);
                    }
                    
                    resolve(connectionStats);
                });

            } catch (error) {
                connectionStats.error = error.message;
                this.stats.connectionsFailed++;
                this.error(`Connection ${connectionId}: Failed to create WebSocket`, error);
                resolve(connectionStats);
            }
        });
    }

    sendTestMessages(ws, connectionStats, resolve) {
        let messagesSent = 0;
        
        const sendMessage = () => {
            if (messagesSent >= this.config.messagesPerConnection || ws.readyState !== WebSocket.OPEN) {
                return;
            }
            
            messagesSent++;
            const messageId = messagesSent;
            const sentTime = performance.now();
            
            const message = JSON.stringify({
                id: messageId,
                method: 'Runtime.evaluate',
                params: {
                    expression: `Math.random() * ${messageId}`
                },
                sentTime: sentTime
            });
            
            try {
                ws.send(message);
                
                // Schedule next message
                setTimeout(sendMessage, 100); // 10 messages per second per connection
            } catch (error) {
                connectionStats.messagesFailed++;
                this.stats.messagesFailed++;
                this.error(`Failed to send message ${messageId}`, error);
            }
        };
        
        // Start sending messages
        sendMessage();
    }

    async runLoadTest() {
        this.log('Chrome Debugger Nginx Proxy Load Test');
        this.log('='.repeat(50));
        this.log(`Configuration:`);
        this.log(`  Host: ${this.config.host}:${this.config.port}`);
        this.log(`  Concurrent connections: ${this.config.concurrentConnections}`);
        this.log(`  Messages per connection: ${this.config.messagesPerConnection}`);
        this.log(`  Test duration: ${this.config.testDuration / 1000}s`);
        this.log(`  Ramp-up time: ${this.config.rampUpTime / 1000}s`);
        
        // Discover WebSocket URL
        let wsUrl;
        try {
            wsUrl = await this.discoverWebSocketUrl();
            this.log(`WebSocket URL: ${wsUrl}`);
        } catch (error) {
            this.error('Failed to discover WebSocket URL', error);
            return false;
        }
        
        this.startTime = performance.now();
        const connectionPromises = [];
        
        // Ramp up connections gradually
        const rampUpInterval = this.config.rampUpTime / this.config.concurrentConnections;
        
        for (let i = 0; i < this.config.concurrentConnections; i++) {
            setTimeout(() => {
                const connectionPromise = this.createTestConnection(i + 1, wsUrl);
                connectionPromises.push(connectionPromise);
            }, i * rampUpInterval);
        }
        
        // Wait for test duration or all connections to complete
        const testTimeout = setTimeout(() => {
            this.log('Test duration reached, closing remaining connections...');
            this.activeConnections.forEach(ws => {
                if (ws.readyState === WebSocket.OPEN) {
                    ws.close();
                }
            });
        }, this.config.testDuration);
        
        try {
            const results = await Promise.all(connectionPromises);
            clearTimeout(testTimeout);
            
            this.generateReport(results);
            return this.stats.connectionsFailed === 0;
        } catch (error) {
            clearTimeout(testTimeout);
            this.error('Load test failed', error);
            return false;
        }
    }

    generateReport(connectionResults) {
        const endTime = performance.now();
        const totalDuration = (endTime - this.startTime) / 1000;
        
        this.log('\n' + '='.repeat(50));
        this.log('LOAD TEST RESULTS');
        this.log('='.repeat(50));
        
        // Connection statistics
        this.log(`\nConnection Statistics:`);
        this.log(`  Total connections attempted: ${this.config.concurrentConnections}`);
        this.log(`  Connections started: ${this.stats.connectionsStarted}`);
        this.log(`  Connections completed: ${this.stats.connectionsCompleted}`);
        this.log(`  Connections failed: ${this.stats.connectionsFailed}`);
        
        if (this.stats.connectionTimes.length > 0) {
            const avgConnectionTime = this.stats.connectionTimes.reduce((a, b) => a + b, 0) / this.stats.connectionTimes.length;
            const maxConnectionTime = Math.max(...this.stats.connectionTimes);
            const minConnectionTime = Math.min(...this.stats.connectionTimes);
            
            this.log(`  Average connection time: ${avgConnectionTime.toFixed(2)}ms`);
            this.log(`  Min connection time: ${minConnectionTime.toFixed(2)}ms`);
            this.log(`  Max connection time: ${maxConnectionTime.toFixed(2)}ms`);
        }
        
        // Message statistics
        this.log(`\nMessage Statistics:`);
        this.log(`  Total messages expected: ${this.config.concurrentConnections * this.config.messagesPerConnection}`);
        this.log(`  Messages succeeded: ${this.stats.messagesSucceeded}`);
        this.log(`  Messages failed: ${this.stats.messagesFailed}`);
        this.log(`  Success rate: ${((this.stats.messagesSucceeded / (this.stats.messagesSucceeded + this.stats.messagesFailed)) * 100).toFixed(2)}%`);
        
        // Calculate response time statistics from all connections
        const allResponseTimes = [];
        connectionResults.forEach(result => {
            allResponseTimes.push(...result.responseTimes);
        });
        
        if (allResponseTimes.length > 0) {
            allResponseTimes.sort((a, b) => a - b);
            const avgResponseTime = allResponseTimes.reduce((a, b) => a + b, 0) / allResponseTimes.length;
            const p50 = allResponseTimes[Math.floor(allResponseTimes.length * 0.5)];
            const p90 = allResponseTimes[Math.floor(allResponseTimes.length * 0.9)];
            const p95 = allResponseTimes[Math.floor(allResponseTimes.length * 0.95)];
            const p99 = allResponseTimes[Math.floor(allResponseTimes.length * 0.99)];
            const maxResponseTime = Math.max(...allResponseTimes);
            const minResponseTime = Math.min(...allResponseTimes);
            
            this.log(`\nResponse Time Statistics:`);
            this.log(`  Average response time: ${avgResponseTime.toFixed(2)}ms`);
            this.log(`  Min response time: ${minResponseTime.toFixed(2)}ms`);
            this.log(`  Max response time: ${maxResponseTime.toFixed(2)}ms`);
            this.log(`  50th percentile: ${p50.toFixed(2)}ms`);
            this.log(`  90th percentile: ${p90.toFixed(2)}ms`);
            this.log(`  95th percentile: ${p95.toFixed(2)}ms`);
            this.log(`  99th percentile: ${p99.toFixed(2)}ms`);
        }
        
        // Performance metrics
        this.log(`\nPerformance Metrics:`);
        this.log(`  Total test duration: ${totalDuration.toFixed(2)}s`);
        this.log(`  Messages per second: ${(this.stats.messagesSucceeded / totalDuration).toFixed(2)}`);
        this.log(`  Connections per second: ${(this.stats.connectionsStarted / totalDuration).toFixed(2)}`);
        
        // Error summary
        if (this.stats.errors.length > 0) {
            this.log(`\nErrors (${this.stats.errors.length}):`);
            const errorCounts = {};
            this.stats.errors.forEach(error => {
                const key = error.error || error.message;
                errorCounts[key] = (errorCounts[key] || 0) + 1;
            });
            
            Object.entries(errorCounts).forEach(([error, count]) => {
                this.log(`  ${error}: ${count} occurrences`);
            });
        }
        
        // Overall assessment
        const successRate = (this.stats.messagesSucceeded / (this.stats.messagesSucceeded + this.stats.messagesFailed)) * 100;
        
        this.log(`\nOverall Assessment:`);
        if (successRate >= 99) {
            this.log('  🎉 Excellent: Very high success rate, proxy is performing well');
        } else if (successRate >= 95) {
            this.log('  ✅ Good: High success rate, proxy is stable');
        } else if (successRate >= 90) {
            this.log('  ⚠️  Fair: Acceptable success rate, consider optimization');
        } else {
            this.log('  ❌ Poor: Low success rate, investigation needed');
        }
    }
}

async function main() {
    const args = process.argv.slice(2);
    const config = {};
    
    // Parse command line arguments
    for (let i = 0; i < args.length; i += 2) {
        const key = args[i].replace(/^--/, '');
        const value = args[i + 1];
        
        switch (key) {
            case 'port':
                config.port = parseInt(value);
                break;
            case 'connections':
                config.concurrentConnections = parseInt(value);
                break;
            case 'messages':
                config.messagesPerConnection = parseInt(value);
                break;
            case 'duration':
                config.testDuration = parseInt(value) * 1000;
                break;
            case 'rampup':
                config.rampUpTime = parseInt(value) * 1000;
                break;
            case 'help':
                console.log(`
Usage: node load-test.js [options]

Options:
  --port N          Chrome debugger port (default: 48333)
  --connections N   Number of concurrent connections (default: 10)
  --messages N      Messages per connection (default: 50)
  --duration N      Test duration in seconds (default: 30)
  --rampup N        Ramp-up time in seconds (default: 5)
  --help           Show this help message

Examples:
  node load-test.js --port 48333 --connections 20 --messages 100
  node load-test.js --duration 60 --rampup 10
`);
                process.exit(0);
                break;
        }
    }
    
    const tester = new ChromeProxyLoadTester(config);
    
    try {
        const success = await tester.runLoadTest();
        process.exit(success ? 0 : 1);
    } catch (error) {
        console.error('Fatal error during load test:', error);
        process.exit(1);
    }
}

if (require.main === module) {
    main();
}

module.exports = ChromeProxyLoadTester;