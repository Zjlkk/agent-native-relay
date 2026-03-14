#!/usr/bin/env node
/**
 * Agent Native Connector
 *
 * Bridges local OpenClaw WebSocket ↔ Agent Native Relay
 * Runs on the user's OpenClaw server.
 *
 * Usage: node bridge.js --token TOKEN --relay wss://relay.example.com
 */

const WebSocket = require("ws");

// Parse args
const args = process.argv.slice(2);
function getArg(name) {
  const i = args.indexOf(`--${name}`);
  return i !== -1 && args[i + 1] ? args[i + 1] : null;
}

const TOKEN = getArg("token") || process.env.AN_TOKEN;
const RELAY_URL = getArg("relay") || process.env.AN_RELAY || "wss://relay.example.com";
const LOCAL_URL = getArg("local") || process.env.AN_LOCAL || "ws://127.0.0.1:18789";

if (!TOKEN) {
  console.error("Error: --token is required");
  process.exit(1);
}

let relayWs = null;
let localWs = null;
let reconnectTimer = null;
let reconnectAttempts = 0;

function log(...args) {
  console.log(`[agent-native]`, ...args);
}

// ── Connect to relay ──
function connectRelay() {
  const url = `${RELAY_URL}?role=connector&token=${TOKEN}`;
  log(`Connecting to relay...`);

  relayWs = new WebSocket(url);

  relayWs.on("open", () => {
    log("Connected to relay");
    reconnectAttempts = 0;
    // Connect to local OpenClaw
    connectLocal();
  });

  relayWs.on("message", (data) => {
    // Forward to local OpenClaw
    if (localWs && localWs.readyState === WebSocket.OPEN) {
      localWs.send(data);
    }
  });

  relayWs.on("close", () => {
    log("Relay connection closed");
    scheduleReconnect();
  });

  relayWs.on("error", (err) => {
    log("Relay error:", err.message);
  });
}

// ── Connect to local OpenClaw ──
function connectLocal() {
  log(`Connecting to local OpenClaw at ${LOCAL_URL}...`);

  localWs = new WebSocket(LOCAL_URL);

  localWs.on("open", () => {
    log("Connected to local OpenClaw");
  });

  localWs.on("message", (data) => {
    // Forward to relay → mobile app
    if (relayWs && relayWs.readyState === WebSocket.OPEN) {
      relayWs.send(data);
    }
  });

  localWs.on("close", () => {
    log("Local OpenClaw connection closed, reconnecting in 3s...");
    setTimeout(connectLocal, 3000);
  });

  localWs.on("error", (err) => {
    log("Local error:", err.message);
  });
}

// ── Reconnect to relay with exponential backoff ──
function scheduleReconnect() {
  if (reconnectTimer) return;
  const delay = Math.min(30, Math.pow(2, reconnectAttempts));
  reconnectAttempts++;
  log(`Reconnecting to relay in ${delay}s...`);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectRelay();
  }, delay * 1000);
}

// ── Start ──
log(`Token: ${TOKEN.slice(0, 8)}...`);
log(`Relay: ${RELAY_URL}`);
log(`Local: ${LOCAL_URL}`);
connectRelay();

// Keep alive
process.on("SIGINT", () => {
  log("Shutting down...");
  relayWs?.close();
  localWs?.close();
  process.exit(0);
});
