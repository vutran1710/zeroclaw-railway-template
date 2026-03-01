#!/bin/bash
set -e

# ═══════════════════════════════════════════════════════════════════
# ZeroClaw Railway Template — start.sh
# Supports two modes:
#   1. Managed (CLAWLAUNCHER_MODE=managed): auto-generates config from env vars,
#      runs daemon + health sidecar + periodic tenant validation
#   2. Interactive (default): waits for manual onboard, then runs daemon
#
# Tickets: P2-01, P2-02, P2-03, P2-04, P2-07, P2-08, P2-11
# ═══════════════════════════════════════════════════════════════════

CONFIG_FILE="/data/.zeroclaw/config.toml"
IDENTITY_FILE="/data/.zeroclaw/IDENTITY.md"
DAEMON_PID=""

# ─── P2-07: Generate model routes + query classification ─────────

generate_model_routes() {
    echo "Generating model routes from BOT_CONFIG_JSON..."

    local auto_routing
    auto_routing=$(echo "$BOT_CONFIG_JSON" | jq -r '.model_routing.auto_routing // true')
    local fallback_model
    fallback_model=$(echo "$BOT_CONFIG_JSON" | jq -r '.model_routing.fallback_model // empty')

    # If auto_routing is false and we have a fallback, override default_model
    if [ "$auto_routing" = "false" ] && [ -n "$fallback_model" ]; then
        sed -i "s/^default_model = .*/default_model = \"${fallback_model}\"/" "$CONFIG_FILE"
    fi

    # Generate [[model_routes]] for each task
    local tasks
    tasks=$(echo "$BOT_CONFIG_JSON" | jq -r '.model_routing.routes // {} | keys[]')

    echo "" >> "$CONFIG_FILE"
    for task in $tasks; do
        local model
        model=$(echo "$BOT_CONFIG_JSON" | jq -r ".model_routing.routes.\"$task\"")
        cat >> "$CONFIG_FILE" << ROUTE

[[model_routes]]
hint = "${task}"
provider = "openrouter"
model = "${model}"
ROUTE
    done

    # Generate [query_classification] only if auto_routing is true
    if [ "$auto_routing" = "true" ]; then
        cat >> "$CONFIG_FILE" << 'CLASSIFICATION'

[query_classification]
enabled = true

[[query_classification.rules]]
hint = "coding"
keywords = ["code", "function", "debug", "error", "compile", "implement", "fix", "bug", "syntax", "refactor", "test"]
patterns = ["```", "fn ", "def ", "class ", "import ", "const ", "let ", "var "]
priority = 20

[[query_classification.rules]]
hint = "math_logic"
keywords = ["calculate", "solve", "prove", "equation", "math", "formula", "theorem", "integral"]
priority = 15

[[query_classification.rules]]
hint = "analysis"
keywords = ["analyze", "compare", "evaluate", "assess", "review", "examine", "interpret"]
min_length = 200
priority = 10

[[query_classification.rules]]
hint = "research"
keywords = ["research", "find", "search", "investigate", "look up", "what is", "explain", "how does"]
priority = 10

[[query_classification.rules]]
hint = "writing"
keywords = ["write", "draft", "compose", "essay", "article", "email", "summarize", "rewrite", "edit"]
priority = 8

[[query_classification.rules]]
hint = "general_chat"
keywords = ["hi", "hello", "thanks", "how are", "hey", "good morning", "good night"]
max_length = 50
priority = 1
CLASSIFICATION
    fi

    echo "Model routes generated."
}

# ─── P2-08: Generate IDENTITY.md ─────────────────────────────────

generate_identity() {
    echo "Generating IDENTITY.md..."

    local plan_name="${PLAN_ID:-your}"
    local username="${TELEGRAM_USERNAME}"

    # Build integrations list from BOT_CONFIG_JSON
    local integrations_text=""
    if [ -n "$BOT_CONFIG_JSON" ]; then
        local enabled
        enabled=$(echo "$BOT_CONFIG_JSON" | jq -r '
            .integrations // {} | to_entries[]
            | select(.value == true) | .key
        ')
        if [ -n "$enabled" ]; then
            integrations_text="## Enabled Integrations
"
            for integration in $enabled; do
                case "$integration" in
                    github) integrations_text+="- **GitHub**: Access repos, issues, pull requests
" ;;
                    gmail) integrations_text+="- **Gmail**: Read and draft emails
" ;;
                    google_docs) integrations_text+="- **Google Docs**: Create and edit documents
" ;;
                    google_spreadsheet) integrations_text+="- **Google Sheets**: Query and update spreadsheets
" ;;
                    notebook_llm) integrations_text+="- **NotebookLM**: Access research notebooks
" ;;
                    opencode) integrations_text+="- **OpenCode**: Run code in sandboxed environment
" ;;
                    jira) integrations_text+="- **Jira**: Manage tickets and sprints
" ;;
                esac
            done
        fi
    fi

    # Budget info
    local budget_text=""
    if [ -n "$MONTHLY_LIMIT_USD" ]; then
        budget_text="You operate within a \$${MONTHLY_LIMIT_USD}/month AI credit budget"
        if [ -n "$DAILY_LIMIT_USD" ]; then
            budget_text+=" with a \$${DAILY_LIMIT_USD}/day spending cap"
        fi
        budget_text+=". Be mindful of cost — prefer efficient responses when possible."
    else
        budget_text="You operate on a pay-as-you-go plan with no fixed budget limit. The user manages their own AI credit balance."
    fi

    cat > "$IDENTITY_FILE" << IDENTITY
# ClawLauncher AI Assistant

You are a private AI assistant deployed via ClawLauncher for @${username} on Telegram.

## About You

- You are a dedicated, personal AI bot running 24/7 on your own infrastructure
- You have full autonomy over your environment — you can install packages, run commands, access the filesystem
- You are powered by multiple AI models via OpenRouter, with intelligent routing based on task type
- Your primary interface is Telegram

## Your User

- Telegram username: @${username}
- Subscription plan: ${plan_name}
- ${budget_text}

## Guidelines

- Be helpful, concise, and proactive
- You can execute commands, write files, and use tools autonomously
- For coding tasks, provide working solutions with explanations
- For research, be thorough but summarize key findings
- Respect the user's time — be direct, avoid unnecessary preamble
- If you're unsure about something, say so honestly

${integrations_text}
IDENTITY

    echo "IDENTITY.md generated."
}

# ─── P2-03: Tenant Validation ────────────────────────────────────

validate_tenant_startup() {
    echo "Validating tenant with backend..."

    local response
    response=$(curl -sf -X POST "${BACKEND_URL}/tenant-validate" \
        -H "Content-Type: application/json" \
        -H "x-service-key: ${SERVICE_AUTH_KEY}" \
        -d "{\"tenant_id\": \"${TENANT_ID}\"}" 2>&1) || true

    if [ -z "$response" ]; then
        echo "WARNING: Could not reach backend for tenant validation. Starting anyway..."
        return 0
    fi

    local valid
    valid=$(echo "$response" | jq -r '.valid // false')

    if [ "$valid" != "true" ]; then
        local reason
        reason=$(echo "$response" | jq -r '.reason // "unknown"')
        # Allow 'provisioning' status — bot starts before activation completes
        if [ "$reason" = "provisioning" ]; then
            echo "Tenant is still provisioning. Starting anyway (will self-activate via provision-complete)."
            return 0
        fi
        echo "ERROR: Tenant validation failed — reason: ${reason}"
        echo "Bot will not start. Tenant status must be 'active' or 'provisioning'."
        exit 1
    fi

    echo "Tenant validated successfully."
}

validate_tenant_periodic() {
    while true; do
        sleep 300  # 5 minutes

        local response
        response=$(curl -sf -X POST "${BACKEND_URL}/tenant-validate" \
            -H "Content-Type: application/json" \
            -H "x-service-key: ${SERVICE_AUTH_KEY}" \
            -d "{\"tenant_id\": \"${TENANT_ID}\"}" 2>&1) || true

        if [ -z "$response" ]; then
            echo "WARNING: Periodic validation — could not reach backend. Continuing..."
            continue
        fi

        local valid
        valid=$(echo "$response" | jq -r '.valid // false')

        if [ "$valid" != "true" ]; then
            local reason
            reason=$(echo "$response" | jq -r '.reason // "unknown"')
            echo "FATAL: Tenant no longer valid — reason: ${reason}. Shutting down daemon."
            kill "$DAEMON_PID" 2>/dev/null || true
            exit 1
        fi
    done
}

# ─── P2-02: Health Endpoint ──────────────────────────────────────

start_health_server() {
    # Node.js HTTP server — more reliable than netcat for persistent health endpoint
    node /app/health-server.js &
}

# ─── P2-01: Generate Managed Config ──────────────────────────────

generate_managed_config() {
    # Validate required env vars
    local required_vars="BOT_TOKEN TENANT_ID BACKEND_URL OPENROUTER_API_KEY DEFAULT_MODEL TELEGRAM_USERNAME"
    for var in $required_vars; do
        if [ -z "${!var}" ]; then
            echo "ERROR: Required env var $var is not set. Cannot start managed bot."
            exit 1
        fi
    done

    echo "Generating config.toml..."

    # Base config
    cat > "$CONFIG_FILE" << TOML_BASE
# Auto-generated by ClawLauncher managed mode
# Tenant: ${TENANT_ID}
# Plan: ${PLAN_ID:-unknown}

default_provider = "openrouter"
default_model = "${DEFAULT_MODEL}"
default_temperature = 0.7

[autonomy]
level = "full"
workspace_only = false
allowed_commands = []
forbidden_paths = []
max_actions_per_hour = 100
max_cost_per_day_cents = 1000

[channels_config]
cli = false

[channels_config.telegram]
bot_token = "${BOT_TOKEN}"
allowed_users = ["${TELEGRAM_USERNAME}"]
TOML_BASE

    # P2-04: Cost enforcement
    if [ -n "$DAILY_LIMIT_USD" ] || [ -n "$MONTHLY_LIMIT_USD" ]; then
        echo "" >> "$CONFIG_FILE"
        echo "[cost]" >> "$CONFIG_FILE"
        if [ -n "$DAILY_LIMIT_USD" ]; then
            echo "daily_limit_usd = ${DAILY_LIMIT_USD}" >> "$CONFIG_FILE"
        fi
        if [ -n "$MONTHLY_LIMIT_USD" ]; then
            echo "monthly_limit_usd = ${MONTHLY_LIMIT_USD}" >> "$CONFIG_FILE"
        fi
    fi

    # P2-07: Model routes from BOT_CONFIG_JSON
    if [ -n "$BOT_CONFIG_JSON" ]; then
        generate_model_routes
    fi

    echo "config.toml generated."

    # P2-08: Identity
    generate_identity
}

# ─── Notify backend that provisioning is complete ────────────────

notify_provision_complete() {
    echo "Waiting for daemon to be ready..."

    # Poll local health endpoint until it responds (max 60s)
    local deadline=$((SECONDS + 60))
    while [ $SECONDS -lt $deadline ]; do
        if curl -sf http://localhost:3000/health > /dev/null 2>&1; then
            echo "Daemon is healthy."
            break
        fi
        sleep 2
    done

    echo "Notifying backend: provision-complete..."
    local response
    response=$(curl -sf -X POST "${BACKEND_URL}/provision-complete" \
        -H "Content-Type: application/json" \
        -H "x-service-key: ${SERVICE_AUTH_KEY}" \
        -d "{\"tenant_id\": \"${TENANT_ID}\"}" 2>&1) || true

    if [ -n "$response" ]; then
        local success
        success=$(echo "$response" | jq -r '.success // false')
        if [ "$success" = "true" ]; then
            echo "Backend notified: tenant is now active."
        else
            echo "WARNING: provision-complete response: $response"
        fi
    else
        echo "WARNING: Could not reach backend for provision-complete. Will retry on next validation cycle."
    fi
}

# ─── P2-11: Start Managed (daemon + sidecars) ────────────────────

start_managed() {
    echo "Starting managed bot..."

    # Export OPENROUTER_API_KEY as ZEROCLAW_API_KEY (ZeroClaw reads this env var)
    export ZEROCLAW_API_KEY="${OPENROUTER_API_KEY}"

    # Health server already started at top of script (HEALTH_PID)

    # Start periodic tenant validation in background (P2-03)
    validate_tenant_periodic &
    local validation_pid=$!
    echo "Periodic validation started (PID: $validation_pid)"

    # Start ZeroClaw daemon
    echo "Starting ZeroClaw daemon..."
    zeroclaw daemon &
    DAEMON_PID=$!
    echo "ZeroClaw daemon started (PID: $DAEMON_PID)"

    # Notify backend that bot is ready (runs in background, non-blocking)
    notify_provision_complete &

    # Trap to clean up on exit
    trap "kill $HEALTH_PID $validation_pid $DAEMON_PID 2>/dev/null; exit" EXIT TERM INT

    # Wait for daemon — if it dies, cleanup happens via trap
    wait $DAEMON_PID
    local exit_code=$?
    echo "ZeroClaw daemon exited with code $exit_code."
    exit $exit_code
}

# ═══════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════

# ─── Start health server immediately (Railway healthcheck) ───────

node /app/health-server.js &
HEALTH_PID=$!
echo "Health endpoint started on :3000 (PID: $HEALTH_PID)"

# ─── Shared Setup ─────────────────────────────────────────────────

mkdir -p /data/.zeroclaw /data/.zeroclaw/logs /data/.npm-global /data/.npm-cache

# npm persistent storage
npm config set prefix '/data/.npm-global'
npm config set cache '/data/.npm-cache'

# Install npm packages from persistent list (if exists)
NPM_PACKAGES_FILE="/data/.zeroclaw/npm-packages.txt"
if [ -f "$NPM_PACKAGES_FILE" ]; then
    echo "Installing npm packages from $NPM_PACKAGES_FILE..."
    while IFS= read -r package || [[ -n "$package" ]]; do
        [[ -z "$package" || "$package" =~ ^# ]] && continue
        if ! npm list -g "$package" &>/dev/null; then
            echo "Installing $package..."
            npm install -g "$package"
        else
            echo "$package is already installed"
        fi
    done < "$NPM_PACKAGES_FILE"
fi

# Install Homebrew if not present
if [ ! -f "/data/.linuxbrew/bin/brew" ]; then
    echo "Installing Homebrew to persistent storage..."
    export NONINTERACTIVE=1
    export HOMEBREW_PREFIX=/data/.linuxbrew
    export HOMEBREW_CELLAR=/data/.linuxbrew/Cellar
    export HOMEBREW_REPOSITORY=/data/.linuxbrew/Homebrew
    git clone --depth=1 https://github.com/Homebrew/brew "$HOMEBREW_REPOSITORY"
    mkdir -p "$HOMEBREW_PREFIX"/{bin,etc,include,lib,opt,sbin,share,var}
    ln -sf "$HOMEBREW_REPOSITORY/bin/brew" "$HOMEBREW_PREFIX/bin/brew"
    echo "Homebrew installed successfully!"
fi

eval "$(/data/.linuxbrew/bin/brew shellenv)" 2>/dev/null || true

# Install Homebrew packages from persistent list (if exists)
HOMEBREW_PACKAGES_FILE="/data/.zeroclaw/brew-packages.txt"
if [ -f "$HOMEBREW_PACKAGES_FILE" ]; then
    echo "Installing Homebrew packages from $HOMEBREW_PACKAGES_FILE..."
    while IFS= read -r package || [[ -n "$package" ]]; do
        [[ -z "$package" || "$package" =~ ^# ]] && continue
        if ! brew list "$package" &>/dev/null; then
            echo "Installing $package..."
            brew install "$package"
        else
            echo "$package is already installed"
        fi
    done < "$HOMEBREW_PACKAGES_FILE"
fi

# ─── Mode Selection ──────────────────────────────────────────────

if [ "$CLAWLAUNCHER_MODE" = "managed" ]; then
    echo "=== ClawLauncher Managed Mode ==="

    # Generate config + identity
    generate_managed_config

    # Validate tenant before starting
    validate_tenant_startup

    # Start daemon + sidecars (does not return)
    start_managed
else
    # Interactive mode (original behavior)
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "=========================================="
        echo "ZeroClaw is not configured yet!"
        echo ""
        echo "To get started:"
        echo "1. Open Railway terminal for this service"
        echo "2. Run: zeroclaw onboard --api-key YOUR_KEY --provider openrouter"
        echo "   Or: zeroclaw onboard --interactive"
        echo ""
        echo "3. Restart the container after configuration"
        echo "=========================================="
        echo ""
        echo "Container is running but waiting for config..."
        echo "(Keep this running so you can access the terminal)"

        while [ ! -f "$CONFIG_FILE" ]; do
            sleep 5
        done

        echo "Config detected! Starting ZeroClaw..."
    fi

    echo "Starting ZeroClaw daemon..."
    exec zeroclaw daemon
fi
