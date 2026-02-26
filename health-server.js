// P2-02: Lightweight health endpoint for Railway healthcheck.
// Runs on port 8080, returns JSON with tenant info and uptime.

const http = require('http');

const startTime = Date.now();
const tenantId = process.env.TENANT_ID || 'unknown';
const botUsername = process.env.TELEGRAM_USERNAME || 'unknown';
const planId = process.env.PLAN_ID || 'unknown';

const server = http.createServer((req, res) => {
  const uptimeSeconds = Math.floor((Date.now() - startTime) / 1000);
  const body = JSON.stringify({
    tenant_id: tenantId,
    bot_username: botUsername,
    uptime_seconds: uptimeSeconds,
    status: 'running',
    plan_id: planId,
  });

  res.writeHead(200, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
});

server.listen(8080, () => {
  console.log('Health server listening on :8080');
});
