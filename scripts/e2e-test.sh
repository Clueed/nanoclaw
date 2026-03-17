#!/usr/bin/env bash
#
# NanoClaw E2E Test Script
#
# Tests the full pipeline: credential proxy → container → Claude Agent SDK → API
# without needing to send real messages through Telegram/WhatsApp.
#
# Usage:
#   ./scripts/e2e-test.sh              # Full e2e test (proxy + container)
#   ./scripts/e2e-test.sh --api-only   # Test just the API endpoint directly
#   ./scripts/e2e-test.sh --proxy-only # Test just through the credential proxy
#

set -uo pipefail
cd "$(dirname "$0")/.."

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[e2e]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# ── Load .env ──────────────────────────────────────────────────────────────────
load_env() {
  local env_file=".env"
  if [[ ! -f "$env_file" ]]; then
    fail ".env file not found"
    exit 1
  fi

  while IFS= read -r line; do
    line="${line%%#*}"   # strip comments
    line="${line#"${line%%[![:space:]]*}"}"  # trim leading whitespace
    [[ -z "$line" ]] && continue
    [[ "$line" != *=* ]] && continue
    local key="${line%%=*}"
    local value="${line#*=}"
    value="${value#\"}" ; value="${value%\"}"
    value="${value#\'}" ; value="${value%\'}"
    eval "ENV_${key}=\"\${value}\""
  done < "$env_file"
}

load_env

API_KEY="${ENV_ANTHROPIC_API_KEY:-}"
BASE_URL="${ENV_ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
AUTH_TOKEN="${ENV_ANTHROPIC_AUTH_TOKEN:-${ENV_CLAUDE_CODE_OAUTH_TOKEN:-}}"
MODEL="${ENV_ANTHROPIC_MODEL:-claude-sonnet-4-20250514}"
PROXY_PORT="${ENV_CREDENTIAL_PROXY_PORT:-3001}"

# ── Step 1: Direct API test ───────────────────────────────────────────────────
test_api_direct() {
  log "Testing API endpoint directly: ${BASE_URL}"

  # Determine auth header
  local auth_header
  if [[ -n "$API_KEY" ]]; then
    auth_header="-H x-api-key:${API_KEY}"
    log "  Auth mode: x-api-key"
  elif [[ -n "$AUTH_TOKEN" ]]; then
    auth_header="-H Authorization:Bearer ${AUTH_TOKEN}"
    log "  Auth mode: Bearer token"
  else
    fail "No API key or auth token found in .env"
    return 1
  fi

  log "  Model: ${MODEL}"

  local response
  response=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/v1/messages" \
    -H "content-type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    ${auth_header} \
    -d "{\"model\":\"${MODEL}\",\"max_tokens\":100,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: E2E_API_OK\"}]}" \
    --connect-timeout 10 \
    --max-time 60 2>&1) || true

  local http_code="${response##*$'\n'}"
  local body="${response%$'\n'*}"

  log "  HTTP ${http_code}"
  if [[ "$http_code" == "200" ]]; then
    if echo "$body" | grep -q "E2E_API_OK"; then
      pass "Direct API: response contains E2E_API_OK"
    else
      warn "Direct API: got 200 but response doesn't contain E2E_API_OK"
      echo "  Response: ${body:0:300}"
    fi
    return 0
  else
    fail "Direct API: HTTP ${http_code}"
    echo "  Response: ${body:0:300}"

    # Try alternate auth methods
    log "  Trying alternate auth methods..."

    # Try Bearer with the API key
    if [[ -n "$API_KEY" ]]; then
      local alt_response
      alt_response=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/v1/messages" \
        -H "content-type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -H "Authorization: Bearer ${API_KEY}" \
        -d "{\"model\":\"${MODEL}\",\"max_tokens\":50,\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}" \
        --connect-timeout 10 \
        --max-time 30 2>&1) || true
      local alt_code="${alt_response##*$'\n'}"
      local alt_body="${alt_response%$'\n'*}"
      if [[ "$alt_code" == "200" ]]; then
        pass "Direct API: Bearer auth works! Update .env: move key from ANTHROPIC_API_KEY to ANTHROPIC_AUTH_TOKEN"
        return 0
      else
        log "  Bearer auth: HTTP ${alt_code} - ${alt_body:0:200}"
      fi
    fi

    # Try with Auth token as x-api-key
    if [[ -n "$AUTH_TOKEN" ]]; then
      local alt_response2
      alt_response2=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/v1/messages" \
        -H "content-type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -H "x-api-key: ${AUTH_TOKEN}" \
        -d "{\"model\":\"${MODEL}\",\"max_tokens\":50,\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}" \
        --connect-timeout 10 \
        --max-time 30 2>&1) || true
      local alt_code2="${alt_response2##*$'\n'}"
      local alt_body2="${alt_response2%$'\n'*}"
      if [[ "$alt_code2" == "200" ]]; then
        pass "Direct API: x-api-key auth works! Update .env: move token to ANTHROPIC_API_KEY"
        return 0
      else
        log "  x-api-key auth: HTTP ${alt_code2} - ${alt_body2:0:200}"
      fi
    fi

    return 1
  fi
}

# ── Step 2: Test through credential proxy ─────────────────────────────────────
test_proxy() {
  log "Testing through credential proxy on port ${PROXY_PORT}..."

  # Check if proxy is already running
  local proxy_pid=""
  local started_proxy=false

  if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PROXY_PORT}/" --connect-timeout 2 >/dev/null 2>&1; then
    log "  Proxy already running on port ${PROXY_PORT}"
  else
    log "  Starting credential proxy..."
    node -e "
      import('./dist/credential-proxy.js').then(m => {
        m.startCredentialProxy(${PROXY_PORT}, '127.0.0.1').then(() => {
          console.log('PROXY_READY');
        });
      });
    " &
    proxy_pid=$!
    started_proxy=true

    # Wait for proxy to be ready
    for i in $(seq 1 20); do
      if curl -s -o /dev/null "http://127.0.0.1:${PROXY_PORT}/" --connect-timeout 1 2>/dev/null; then
        break
      fi
      sleep 0.5
    done
    log "  Proxy started (PID: ${proxy_pid})"
  fi

  # Send test request through proxy
  local response
  response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:${PROXY_PORT}/v1/messages" \
    -H "content-type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -H "x-api-key: placeholder" \
    -d "{\"model\":\"${MODEL}\",\"max_tokens\":100,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: E2E_PROXY_OK\"}]}" \
    --connect-timeout 10 \
    --max-time 60 2>&1) || true

  local http_code="${response##*$'\n'}"
  local body="${response%$'\n'*}"

  if [[ "$started_proxy" == "true" && -n "$proxy_pid" ]]; then
    kill "$proxy_pid" 2>/dev/null || true
    wait "$proxy_pid" 2>/dev/null || true
  fi

  log "  Proxy → upstream: HTTP ${http_code}"
  if [[ "$http_code" == "200" ]]; then
    pass "Proxy test passed"
    echo "  Response: ${body:0:300}"
    return 0
  else
    fail "Proxy test: HTTP ${http_code}"
    echo "  Response: ${body:0:300}"

    # Check if auth is the issue
    if echo "$body" | grep -qi "auth"; then
      warn "Authentication failed. The API key may be expired or invalid."
      warn "Verify the key works: curl -s ${BASE_URL}/v1/messages -H 'x-api-key: YOUR_KEY' ..."
    fi

    return 1
  fi
}

# ── Step 3: Full container e2e test ───────────────────────────────────────────
test_container() {
  log "Running full container e2e test..."

  # Ensure container image exists
  if ! docker image inspect nanoclaw-agent:latest >/dev/null 2>&1; then
    fail "Container image nanoclaw-agent:latest not found. Run: ./container/build.sh"
    return 1
  fi

  # Start the credential proxy in background
  local proxy_pid=""
  local started_proxy=false

  if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PROXY_PORT}/" --connect-timeout 2 >/dev/null 2>&1; then
    log "  Proxy already running"
  else
    log "  Starting credential proxy..."
    node -e "
      import('./dist/credential-proxy.js').then(m => {
        m.startCredentialProxy(${PROXY_PORT}, '0.0.0.0').then(() => {
          console.log('PROXY_READY');
        });
      });
    " &
    proxy_pid=$!
    started_proxy=true
    sleep 2
    log "  Proxy started (PID: ${proxy_pid})"
  fi

  # Prepare group directory
  local group_dir="groups/e2e-test"
  local session_dir="data/sessions/e2e-test"
  mkdir -p "$group_dir/logs"
  mkdir -p "${session_dir}/.claude/skills"
  mkdir -p "${session_dir}/agent-runner-src"
  mkdir -p "data/ipc/e2e-test/messages"
  mkdir -p "data/ipc/e2e-test/tasks"
  mkdir -p "data/ipc/e2e-test/input"
  mkdir -p "groups/global"

  # Write clean settings.json (no hardcoded secrets)
  cat > "${session_dir}/.claude/settings.json" << 'SETTINGS'
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD": "1",
    "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "0"
  }
}
SETTINGS

  # Copy agent-runner source
  if [[ -d "container/agent-runner/src" ]]; then
    cp -r container/agent-runner/src/* "${session_dir}/agent-runner-src/"
  fi

  # Copy skills
  if [[ -d "container/skills" ]]; then
    for skill_dir in container/skills/*/; do
      [[ -d "$skill_dir" ]] && cp -r "$skill_dir" "${session_dir}/.claude/skills/"
    done
  fi

  # Clean up stale close sentinel
  rm -f "data/ipc/e2e-test/input/_close"

  # Build container args
  local container_name="nanoclaw-e2e-test-$(date +%s)"
  local docker_args=(
    run -i --rm
    --name "$container_name"
    -e "TZ=UTC"
    -e "ANTHROPIC_BASE_URL=http://host.docker.internal:${PROXY_PORT}"
    --add-host=host.docker.internal:host-gateway
    -v "$(pwd)/${group_dir}:/workspace/group"
    -v "$(pwd)/groups/global:/workspace/global:ro"
    -v "$(pwd)/${session_dir}/.claude:/home/node/.claude"
    -v "$(pwd)/data/ipc/e2e-test:/workspace/ipc"
    -v "$(pwd)/${session_dir}/agent-runner-src:/app/src"
  )

  # Detect auth mode and add appropriate env var
  if [[ -n "$API_KEY" ]]; then
    docker_args+=(-e "ANTHROPIC_API_KEY=placeholder")
    log "  Auth mode: api-key (proxy injects x-api-key)"
  else
    docker_args+=(-e "CLAUDE_CODE_OAUTH_TOKEN=placeholder")
    log "  Auth mode: oauth (proxy injects Bearer token)"
  fi

  # Add model env vars if set
  [[ -n "${ENV_ANTHROPIC_MODEL:-}" ]] && docker_args+=(-e "ANTHROPIC_MODEL=${ENV_ANTHROPIC_MODEL}")
  [[ -n "${ENV_ANTHROPIC_DEFAULT_HAIKU_MODEL:-}" ]] && docker_args+=(-e "ANTHROPIC_DEFAULT_HAIKU_MODEL=${ENV_ANTHROPIC_DEFAULT_HAIKU_MODEL}")
  [[ -n "${ENV_ANTHROPIC_DEFAULT_SONNET_MODEL:-}" ]] && docker_args+=(-e "ANTHROPIC_DEFAULT_SONNET_MODEL=${ENV_ANTHROPIC_DEFAULT_SONNET_MODEL}")
  [[ -n "${ENV_ANTHROPIC_DEFAULT_OPUS_MODEL:-}" ]] && docker_args+=(-e "ANTHROPIC_DEFAULT_OPUS_MODEL=${ENV_ANTHROPIC_DEFAULT_OPUS_MODEL}")
  [[ -n "${ENV_CLAUDE_CODE_SUBAGENT_MODEL:-}" ]] && docker_args+=(-e "CLAUDE_CODE_SUBAGENT_MODEL=${ENV_CLAUDE_CODE_SUBAGENT_MODEL}")

  # Add telemetry/traffic suppression
  [[ -n "${ENV_DISABLE_TELEMETRY:-}" ]] && docker_args+=(-e "DISABLE_TELEMETRY=${ENV_DISABLE_TELEMETRY}")
  [[ -n "${ENV_CLAUDE_CODE_ENABLE_TELEMETRY:-}" ]] && docker_args+=(-e "CLAUDE_CODE_ENABLE_TELEMETRY=${ENV_CLAUDE_CODE_ENABLE_TELEMETRY}")
  [[ -n "${ENV_CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY:-}" ]] && docker_args+=(-e "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=${ENV_CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY}")
  [[ -n "${ENV_CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" ]] && docker_args+=(-e "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=${ENV_CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC}")
  [[ -n "${ENV_SKIP_CLAUDE_API:-}" ]] && docker_args+=(-e "SKIP_CLAUDE_API=${ENV_SKIP_CLAUDE_API}")

  docker_args+=(nanoclaw-agent:latest)

  # Build input JSON
  local input_json
  input_json=$(cat << 'INPUT'
{
  "prompt": "<context timezone=\"UTC\" />\n<messages>\n<message sender=\"E2E Tester\" time=\"now\">@Andy Reply with exactly: E2E_TEST_PASSED</message>\n</messages>",
  "groupFolder": "e2e-test",
  "chatJid": "e2e-test:1",
  "isMain": false,
  "assistantName": "Andy"
}
INPUT
)

  log "  Container: ${container_name}"
  log "  Model: ${MODEL}"
  log "  Running container (timeout: 120s)..."

  # Write close sentinel after a delay (auto-terminate the container)
  (sleep 30 && touch "data/ipc/e2e-test/input/_close" 2>/dev/null) &
  local sentinel_pid=$!

  # Run the container
  local start_time
  start_time=$(date +%s)
  local output
  output=$(echo "$input_json" | timeout 120 docker "${docker_args[@]}" 2>"${group_dir}/logs/e2e-stderr.log") || true
  local exit_code=$?
  local duration=$(( $(date +%s) - start_time ))

  # Kill sentinel writer
  kill "$sentinel_pid" 2>/dev/null || true

  # Cleanup proxy if we started it
  if [[ "$started_proxy" == "true" && -n "$proxy_pid" ]]; then
    kill "$proxy_pid" 2>/dev/null || true
    wait "$proxy_pid" 2>/dev/null || true
  fi

  # Parse results
  log "  Duration: ${duration}s, Exit code: ${exit_code}"

  local stderr_log="${group_dir}/logs/e2e-stderr.log"
  if [[ -f "$stderr_log" ]]; then
    log "  Stderr (last 20 lines):"
    tail -20 "$stderr_log" | sed 's/^/    /'
  fi

  # Extract output between markers
  local result=""
  if echo "$output" | grep -q "NANOCLAW_OUTPUT_START"; then
    result=$(echo "$output" | sed -n '/---NANOCLAW_OUTPUT_START---/,/---NANOCLAW_OUTPUT_END---/p' | grep -v "NANOCLAW_OUTPUT" | tail -1)
  fi

  if [[ -n "$result" ]]; then
    log "  Agent output: ${result:0:500}"

    if echo "$result" | grep -q "E2E_TEST_PASSED"; then
      pass "Full e2e test: Agent responded with E2E_TEST_PASSED"
      return 0
    elif echo "$result" | grep -qi "authentication\|401"; then
      fail "Full e2e test: Authentication failed"
      warn "The API key may be expired or the auth method is wrong."
      warn "Check .env: try switching ANTHROPIC_API_KEY to ANTHROPIC_AUTH_TOKEN (or vice versa)."
      return 1
    elif echo "$result" | grep -qi "model.*not exist\|selected model"; then
      fail "Full e2e test: Model issue"
      warn "The SDK doesn't recognize the configured model."
      warn "Current model: ${MODEL}"
      return 1
    else
      warn "Full e2e test: Unexpected response"
      echo "  ${result:0:500}"
      return 1
    fi
  else
    fail "Full e2e test: No output from container"
    if [[ -f "$stderr_log" ]]; then
      echo "  Full stderr:"
      cat "$stderr_log" | sed 's/^/    /'
    fi
    return 1
  fi
}

# ── Summary helper ────────────────────────────────────────────────────────────
print_config() {
  log "Configuration:"
  log "  ANTHROPIC_BASE_URL:  ${BASE_URL}"
  if [[ -n "$API_KEY" ]]; then
    log "  ANTHROPIC_API_KEY:   set (${#API_KEY} chars)"
  else
    log "  ANTHROPIC_API_KEY:   not set"
  fi
  if [[ -n "$AUTH_TOKEN" ]]; then
    log "  ANTHROPIC_AUTH_TOKEN: set (${#AUTH_TOKEN} chars)"
  else
    log "  ANTHROPIC_AUTH_TOKEN: not set"
  fi
  log "  ANTHROPIC_MODEL:     ${MODEL}"
  log "  PROXY_PORT:          ${PROXY_PORT}"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo "  NanoClaw E2E Test"
  echo "═══════════════════════════════════════════════════"
  echo ""

  print_config

  local mode="${1:-full}"
  local failures=0

  case "$mode" in
    --api-only)
      test_api_direct || ((failures++))
      ;;
    --proxy-only)
      test_proxy || ((failures++))
      ;;
    *)
      test_api_direct || ((failures++))
      echo ""
      test_proxy || ((failures++))
      echo ""
      test_container || ((failures++))
      ;;
  esac

  echo ""
  echo "═══════════════════════════════════════════════════"
  if [[ "$failures" -eq 0 ]]; then
    pass "All tests passed"
  else
    fail "${failures} test(s) failed"
  fi
  echo "═══════════════════════════════════════════════════"
  echo ""

  return "$failures"
}

main "$@"
