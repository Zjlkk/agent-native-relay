#!/bin/bash
# Agent Native Connector — Install Script
# Usage: bash <(curl -fsSL https://cdn.example.com/install.sh) --bot-token TOKEN

set -e

# ── Parse args ──
TOKEN=""
RELAY="ws://127.0.0.1:8787"

while [[ $# -gt 0 ]]; do
  case $1 in
    --bot-token) TOKEN="$2"; shift 2 ;;
    --relay) RELAY="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ -z "$TOKEN" ]; then
  echo "Error: --bot-token is required"
  exit 1
fi

echo "🔗 Agent Native Connector"
echo "   Token: ${TOKEN:0:8}..."
echo ""

# ── Check prerequisites ──
if ! command -v node &> /dev/null; then
  echo "❌ Node.js is required but not found."
  echo "   Install it: https://nodejs.org"
  exit 1
fi

NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
if [ "$NODE_VERSION" -lt 18 ]; then
  echo "❌ Node.js 18+ required (found $(node -v))"
  exit 1
fi

# ── Create install directory ──
INSTALL_DIR="$HOME/.agent-native"
mkdir -p "$INSTALL_DIR"

# ── Download bridge script ──
echo "📦 Installing connector..."
cat > "$INSTALL_DIR/bridge.js" << 'BRIDGE_EOF'
#!/usr/bin/env node
const WebSocket = require("ws");
const TOKEN = process.env.AN_TOKEN;
const RELAY_URL = process.env.AN_RELAY || "wss://relay.example.com";
const LOCAL_URL = process.env.AN_LOCAL || "ws://127.0.0.1:18789";
if (!TOKEN) { console.error("AN_TOKEN required"); process.exit(1); }
let relayWs, localWs, reconnectTimer, reconnectAttempts = 0;
const log = (...a) => console.log("[agent-native]", ...a);
function connectRelay() {
  log("Connecting to relay...");
  relayWs = new WebSocket(`${RELAY_URL}?role=connector&token=${TOKEN}`);
  relayWs.on("open", () => { log("Relay connected"); reconnectAttempts = 0; connectLocal(); });
  relayWs.on("message", (d) => { if (localWs?.readyState === 1) localWs.send(d); });
  relayWs.on("close", () => { log("Relay closed"); scheduleReconnect(); });
  relayWs.on("error", (e) => log("Relay error:", e.message));
}
function connectLocal() {
  log(`Connecting to ${LOCAL_URL}...`);
  localWs = new WebSocket(LOCAL_URL);
  localWs.on("open", () => log("Local connected"));
  localWs.on("message", (d) => { if (relayWs?.readyState === 1) relayWs.send(d); });
  localWs.on("close", () => { log("Local closed, retry in 3s"); setTimeout(connectLocal, 3000); });
  localWs.on("error", (e) => log("Local error:", e.message));
}
function scheduleReconnect() {
  if (reconnectTimer) return;
  const d = Math.min(30, 2 ** reconnectAttempts); reconnectAttempts++;
  log(`Reconnecting in ${d}s...`);
  reconnectTimer = setTimeout(() => { reconnectTimer = null; connectRelay(); }, d * 1000);
}
connectRelay();
process.on("SIGINT", () => { relayWs?.close(); localWs?.close(); process.exit(0); });
BRIDGE_EOF

# ── Install ws dependency ──
cd "$INSTALL_DIR"
if [ ! -f package.json ]; then
  cat > package.json << 'PKG_EOF'
{"name":"agent-native-connector","version":"0.1.0","dependencies":{"ws":"^8.18.0"}}
PKG_EOF
fi
npm install --silent 2>/dev/null

# ── Write env config ──
cat > "$INSTALL_DIR/.env" << ENV_EOF
AN_TOKEN=$TOKEN
AN_RELAY=$RELAY
AN_LOCAL=ws://127.0.0.1:18789
ENV_EOF

# ── Create start script ──
cat > "$INSTALL_DIR/start.sh" << 'START_EOF'
#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$DIR/.env"
export AN_TOKEN AN_RELAY AN_LOCAL
exec node "$DIR/bridge.js"
START_EOF
chmod +x "$INSTALL_DIR/start.sh"

# ── Start the connector ──
echo "🚀 Starting connector..."
source "$INSTALL_DIR/.env"
export AN_TOKEN AN_RELAY AN_LOCAL

# Run in background with nohup
nohup node "$INSTALL_DIR/bridge.js" > "$INSTALL_DIR/connector.log" 2>&1 &
CONNECTOR_PID=$!
echo "$CONNECTOR_PID" > "$INSTALL_DIR/connector.pid"

echo ""
echo "✅ Agent Native Connector is running (PID: $CONNECTOR_PID)"
echo "   Logs: $INSTALL_DIR/connector.log"
echo "   Stop: kill \$(cat $INSTALL_DIR/connector.pid)"
echo ""
echo "   Go back to the app and tap Done."
