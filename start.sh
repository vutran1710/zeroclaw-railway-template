#!/bin/bash
set -e

# ═══════════════════════════════════════════════════════════════════
# ZeroClaw Railway Template — start.sh
# Supports two modes:
#   1. Managed (CLAWLAUNCHER_MODE=managed): renders config from templates,
#      runs daemon + periodic tenant validation
#   2. Interactive (default): waits for manual onboard, then runs daemon
# ═══════════════════════════════════════════════════════════════════

# ─── Guard: prevent double execution ─────────────────────────────
LOCKFILE="/tmp/start.sh.lock"
if [ -f "$LOCKFILE" ]; then
    EXISTING_PID=$(cat "$LOCKFILE" 2>/dev/null)
    # Only treat as duplicate if the stored PID is a different, still-running start.sh.
    # PID 1 (container init) is always alive on restart, so skip self-detection.
    if [ -n "$EXISTING_PID" ] && [ "$EXISTING_PID" != "$$" ] && [ "$EXISTING_PID" != "1" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        echo "start.sh is already running (PID: $EXISTING_PID). Exiting duplicate."
        exit 0
    fi
fi
echo $$ > "$LOCKFILE"
trap "rm -f $LOCKFILE" EXIT

# Kill any stale zeroclaw daemon from a previous run (persistent volume may survive redeploys)
if pgrep -x zeroclaw > /dev/null 2>&1; then
    echo "WARNING: Found stale zeroclaw process(es). Killing before fresh start."
    pkill -x zeroclaw || true
    sleep 1
fi

CONFIG_FILE="/data/.zeroclaw/config.toml"
IDENTITY_FILE="/data/.zeroclaw/IDENTITY.md"
TEMPLATE_DIR="/app/templates"
DAEMON_PID=""

# ─── Virtual desktop (Xvfb + Fluxbox + x11vnc + noVNC) ──────────
start_virtual_desktop() {
    echo "Starting virtual desktop..."

    # Start Xvfb (virtual framebuffer)
    Xvfb :99 -screen 0 "${SCREEN_WIDTH:-1366}x${SCREEN_HEIGHT:-768}x${SCREEN_DEPTH:-24}" -ac +extension GLX +render -noreset &
    sleep 1

    # Start Fluxbox window manager
    fluxbox &
    sleep 0.5

    # Start x11vnc (VNC server on display :99)
    x11vnc -display :99 -nopw -listen 0.0.0.0 -rfbport 5900 -shared -forever -noxdamage &
    sleep 0.5

    # Start noVNC (web-based VNC viewer on port 6080)
    NOVNC_PATH=$(find /usr -path "*/novnc/utils/novnc_proxy" 2>/dev/null | head -1)
    if [ -z "$NOVNC_PATH" ]; then
        NOVNC_PATH=$(find /usr -path "*/novnc/utils/launch.sh" 2>/dev/null | head -1)
    fi
    if [ -n "$NOVNC_PATH" ]; then
        "$NOVNC_PATH" --vnc localhost:5900 --listen 6080 &
    else
        websockify --web /usr/share/novnc 6080 localhost:5900 &
    fi

    echo "  Virtual desktop started (DISPLAY=:99)"
    echo "  noVNC viewer: http://0.0.0.0:6080/vnc.html"
}

# Start virtual desktop if Xvfb is available
if command -v Xvfb >/dev/null 2>&1; then
    start_virtual_desktop
fi

# ─── Model overrides (persisted by /models command) ──────────────

MODEL_OVERRIDES_FILE="/data/.zeroclaw/model-overrides.json"

apply_model_overrides() {
    if [ ! -f "$MODEL_OVERRIDES_FILE" ]; then
        return
    fi

    echo "  Applying model overrides from $MODEL_OVERRIDES_FILE..."

    # Override default_model if set
    local new_default
    new_default=$(jq -r '.default_model // empty' "$MODEL_OVERRIDES_FILE" 2>/dev/null)
    if [ -n "$new_default" ]; then
        sed -i "s/^default_model = .*/default_model = \"${new_default}\"/" "$CONFIG_FILE"
        echo "    default_model -> ${new_default}"
    fi

    # Override per-task model routes
    local tasks
    tasks=$(jq -r '.routes // {} | keys[]' "$MODEL_OVERRIDES_FILE" 2>/dev/null)
    for task in $tasks; do
        local model
        model=$(jq -r ".routes.\"$task\"" "$MODEL_OVERRIDES_FILE")
        if [ -n "$model" ] && [ "$model" != "null" ]; then
            # Find and replace the model for this hint in existing [[model_routes]]
            # Use python for reliable multi-line TOML editing
            python3 -c "
import re, sys
config = open('$CONFIG_FILE').read()
# Pattern: [[model_routes]] block with hint = \"$task\"
pattern = r'(\[\[model_routes\]\]\nhint = \"${task}\"\nprovider = \"openrouter\"\nmodel = \")([^\"]*)(\")'
new_config = re.sub(pattern, r'\g<1>${model}\3', config)
if new_config != config:
    open('$CONFIG_FILE', 'w').write(new_config)
    print('    ${task} -> ${model}')
else:
    print('    ${task}: no matching route found, skipping')
" 2>/dev/null || echo "    WARNING: failed to apply override for ${task}"
        fi
    done
}

# ─── Config rendering: envsubst + dynamic sections ───────────────

render_config() {
    echo "Rendering config.toml from template..."

    # Render base template (substitutes ${VAR} placeholders from env)
    envsubst < "${TEMPLATE_DIR}/config.toml.tmpl" > "$CONFIG_FILE"

    # Append [cost] section for non-PAYG plans (when both limits are set)
    append_cost_section

    # Append model routes from BOT_CONFIG_JSON
    if [ -n "$BOT_CONFIG_JSON" ]; then
        append_model_routes
    fi

    # Apply user's model overrides (if any — saved by /models command)
    apply_model_overrides

    echo "config.toml rendered."
}

append_cost_section() {
    # Only emit [cost] when BOTH daily and monthly limits are non-empty
    # PAYG plans have these as empty/unset — no cost section for them
    if [ -n "$DAILY_LIMIT_USD" ] && [ -n "$MONTHLY_LIMIT_USD" ]; then
        cat >> "$CONFIG_FILE" << COST

[cost]
enabled = true
daily_limit_usd = ${DAILY_LIMIT_USD}
monthly_limit_usd = ${MONTHLY_LIMIT_USD}
COST
        echo "  [cost] section appended (daily=$DAILY_LIMIT_USD, monthly=$MONTHLY_LIMIT_USD)"
    else
        echo "  [cost] section skipped (PAYG — no limits)"
    fi
}

append_model_routes() {
    echo "  Appending model routes from BOT_CONFIG_JSON..."

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

    echo "  Model routes appended."
}

# ─── Identity rendering: envsubst + dynamic sections ─────────────

render_identity() {
    echo "Rendering IDENTITY.md from template..."

    # Render base template
    envsubst < "${TEMPLATE_DIR}/identity.md.tmpl" > "$IDENTITY_FILE"

    # Append budget info
    append_budget_section

    echo "IDENTITY.md rendered."
}

append_budget_section() {
    if [ -n "$MONTHLY_LIMIT_USD" ]; then
        local budget_text="## Budget\n\nYou operate within a \$${MONTHLY_LIMIT_USD}/month AI credit budget"
        if [ -n "$DAILY_LIMIT_USD" ]; then
            budget_text+=" with a \$${DAILY_LIMIT_USD}/day spending cap"
        fi
        budget_text+=". Be mindful of cost — prefer efficient responses when possible."
        echo -e "\n${budget_text}" >> "$IDENTITY_FILE"
    fi
    # PAYG: no budget section — user manages their own balance
}

# ─── Claude Code conditional install ─────────────────────────────

install_claude_code() {
    if [ -z "$BOT_CONFIG_JSON" ]; then
        return
    fi

    local enabled
    enabled=$(echo "$BOT_CONFIG_JSON" | jq -r '.claude_code_enabled // false')

    if [ "$enabled" != "true" ]; then
        return
    fi

    # Check if already installed (persists across redeploys via /data/.npm-global)
    if command -v claude &>/dev/null; then
        echo "  Claude Code CLI already installed: $(claude --version 2>/dev/null || echo 'unknown version')"
        return
    fi

    echo "  Installing Claude Code CLI..."
    if npm install -g @anthropic-ai/claude-code; then
        echo "  Claude Code CLI installed: $(claude --version 2>/dev/null || echo 'unknown version')"
    else
        echo "  WARNING: Claude Code CLI install failed. Bot will start without it."
    fi
}

## NOTE: /claudecode is now handled as a native runtime command in the
## ZeroClaw binary (ChannelRuntimeCommand::ClaudeCodeStart/Exit).
## The old prompt-engineering approach (append_claude_code_section) has
## been removed.

# ─── Seed USER.md with defaults (preserves existing) ─────────────

USER_MD_FILE="/data/.zeroclaw/USER.md"

seed_user_md() {
    if [ -f "$USER_MD_FILE" ]; then
        echo "USER.md already exists — preserving user customizations."
        return
    fi

    echo "Seeding USER.md with defaults..."
    cat > "$USER_MD_FILE" << USERMD
# Name
1claw Assistant

# Style
Helpful, concise, and proactive

# Language
English

# User Bio
Telegram user @${TELEGRAM_USERNAME}
USERMD
    echo "USER.md seeded."
}

# ─── Generate Managed Config ─────────────────────────────────────

generate_managed_config() {
    # Validate required env vars
    local required_vars="BOT_TOKEN TENANT_ID OPENROUTER_API_KEY DEFAULT_MODEL TELEGRAM_USERNAME"
    for var in $required_vars; do
        if [ -z "${!var}" ]; then
            echo "ERROR: Required env var $var is not set. Cannot start managed bot."
            exit 1
        fi
    done

    # Derive CLI gateway config from BOT_CONFIG_JSON
    export CLI_GATEWAY_ALLOWED
    CLI_GATEWAY_ALLOWED=$(echo "$BOT_CONFIG_JSON" | jq -r '.cli_gateway_allowed // "[]"')

    # Render config.toml from template + dynamic sections
    render_config

    # Render IDENTITY.md from template + dynamic sections
    render_identity

    # Seed USER.md with defaults (only if it doesn't exist — preserves user customizations)
    seed_user_md

    # Install Claude Code CLI if enabled in bot_config
    install_claude_code
}

# ─── Start Managed (daemon + sidecars) ───────────────────────────

start_managed() {
    echo "Starting managed bot..."

    # Export OPENROUTER_API_KEY as ZEROCLAW_API_KEY (ZeroClaw reads this env var)
    export ZEROCLAW_API_KEY="${OPENROUTER_API_KEY}"

    # Start ZeroClaw daemon (with pre-flight check for unexpected auto-start)
    if pgrep -x zeroclaw > /dev/null 2>&1; then
        echo "WARNING: zeroclaw process already running before explicit start. Killing it."
        pkill -x zeroclaw || true
        sleep 1
    fi
    echo "Starting ZeroClaw daemon..."
    zeroclaw daemon &
    DAEMON_PID=$!
    echo "ZeroClaw daemon started (PID: $DAEMON_PID)"

    # Trap to clean up on exit
    trap "kill $DAEMON_PID 2>/dev/null; exit" EXIT TERM INT

    # Wait for daemon — if it dies, cleanup happens via trap
    wait $DAEMON_PID
    local exit_code=$?
    echo "ZeroClaw daemon exited with code $exit_code."
    exit $exit_code
}

# ═══════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════

# ─── Shared Setup ─────────────────────────────────────────────────

mkdir -p /data/.zeroclaw /data/.zeroclaw/logs /data/.npm-global /data/.npm-cache

# Claude Code workspace + stale session cleanup
mkdir -p /data/workspace
rm -rf /data/.claude/remote-sessions 2>/dev/null || true

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

# Homebrew: pre-installed in Docker image, just activate shellenv
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
    echo "=== 1claw.network Managed Mode ==="

    # Generate config + identity from templates
    generate_managed_config

    # Start daemon (does not return)
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
