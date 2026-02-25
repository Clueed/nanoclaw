#!/bin/bash
# start-nanoclaw.sh — Start NanoClaw without systemd
# To stop: kill \$(cat /home/claw/nanoclaw/nanoclaw.pid)

set -euo pipefail

cd "/home/claw/nanoclaw"

# Stop existing instance if running
if [ -f "/home/claw/nanoclaw/nanoclaw.pid" ]; then
  OLD_PID=$(cat "/home/claw/nanoclaw/nanoclaw.pid" 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Stopping existing NanoClaw (PID $OLD_PID)..."
    kill "$OLD_PID" 2>/dev/null || true
    sleep 2
  fi
fi

echo "Starting NanoClaw..."
nohup "/home/claw/.nvm/versions/node/v22.22.0/bin/node" "/home/claw/nanoclaw/dist/index.js" \
  >> "/home/claw/nanoclaw/logs/nanoclaw.log" \
  2>> "/home/claw/nanoclaw/logs/nanoclaw.error.log" &

echo $! > "/home/claw/nanoclaw/nanoclaw.pid"
echo "NanoClaw started (PID $!)"
echo "Logs: tail -f /home/claw/nanoclaw/logs/nanoclaw.log"
