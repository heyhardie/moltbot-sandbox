#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox
# This script:
# 1. Runs openclaw onboard --non-interactive to configure from env vars
# 2. Patches config for features onboard doesn't cover (channels, gateway auth)
# 3. Starts the gateway
#
# NOTE: Persistence (backup/restore) is handled by the Sandbox SDK at the
# Worker level, not inside the container. The Worker calls createBackup()
# and restoreBackup() which use squashfs snapshots stored in R2.
# No rclone or R2 credentials are needed inside the container.

set -e

if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

# Config must live under /home/openclaw: that's the HOME the gateway resolves
# ~/.openclaw against, and the only tree the Sandbox SDK backup snapshots.
# /root/.openclaw is NOT a symlink to it — the base image ships /root/.openclaw
# (with state/), so the Dockerfile's ln -s landed inside it as a nested link.
# Patching /root/.openclaw/openclaw.json silently produced a config the
# gateway never read.
export HOME=/home/openclaw
CONFIG_DIR="/home/openclaw/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
WORKSPACE_DIR="/home/openclaw/clawd"
SKILLS_DIR="/home/openclaw/clawd/skills"

echo "Config directory: $CONFIG_DIR"

mkdir -p "$CONFIG_DIR"

# ============================================================
# ONBOARD (only if no config exists yet)
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, running openclaw onboard..."

    # Determine auth choice — openclaw onboard reads the actual key values
    # from environment variables (ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.)
    # so we only pass --auth-choice, never the key itself, to avoid
    # exposing secrets in process arguments visible via ps/proc.
    AUTH_ARGS=""
    if [ -n "$ANTHROPIC_API_KEY" ]; then
        AUTH_ARGS="--auth-choice apiKey"
    elif [ -n "$CLOUDFLARE_AI_GATEWAY_API_KEY" ] && [ -n "$CF_AI_GATEWAY_ACCOUNT_ID" ] && [ -n "$CF_AI_GATEWAY_GATEWAY_ID" ]; then
        AUTH_ARGS="--auth-choice cloudflare-ai-gateway-api-key --cloudflare-ai-gateway-account-id $CF_AI_GATEWAY_ACCOUNT_ID --cloudflare-ai-gateway-gateway-id $CF_AI_GATEWAY_GATEWAY_ID"
    elif [ -n "$OPENAI_API_KEY" ]; then
        AUTH_ARGS="--auth-choice openai-api-key"
    fi

    openclaw onboard --non-interactive --accept-risk \
        --mode local \
        $AUTH_ARGS \
        --gateway-port 18789 \
        --gateway-bind lan \
        --skip-channels \
        --skip-skills \
        --skip-health

    echo "Onboard completed"
else
    echo "Using existing config"
fi

# ============================================================
# PATCH CONFIG (channels, gateway auth, trusted proxies)
# ============================================================
# openclaw onboard handles provider/model config, but we need to patch in:
# - Channel config (Telegram, Discord, Slack)
# - Gateway token auth
# - Trusted proxies for sandbox networking
# - Base URL override for legacy AI Gateway path
node << 'EOFPATCH'
const fs = require('fs');

const configPath = '/home/openclaw/.openclaw/openclaw.json';
console.log('Patching config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

if (process.env.OPENCLAW_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN;
}

// Allow the public Worker origin(s) to connect to the gateway control UI.
// The gateway runs inside a Cloudflare Container behind the Worker, which
// proxies requests from the public domain. Without this, openclaw rejects
// WebSocket connections because the browser's origin doesn't match the
// gateway's localhost. openclaw >= 2026.6 requires exact origins — wildcard
// '*' is no longer honored.
// Security is handled by CF Access + gateway token auth, not origin checks.
config.gateway.controlUi = config.gateway.controlUi || {};
const controlUiOrigins = ['https://miracle.hardie.org'];
if (process.env.WORKER_URL && !controlUiOrigins.includes(process.env.WORKER_URL)) controlUiOrigins.push(process.env.WORKER_URL);
config.gateway.controlUi.allowedOrigins = controlUiOrigins;

if (process.env.OPENCLAW_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Legacy AI Gateway base URL override:
// ANTHROPIC_BASE_URL is picked up natively by the Anthropic SDK,
// so we don't need to patch the provider config. Writing a provider
// entry without a models array breaks OpenClaw's config validation.

// AI Gateway model override (CF_AI_GATEWAY_MODEL=provider/model-id)
// Adds a provider entry for any AI Gateway provider and sets it as default model.
// Examples:
//   workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast
//   openai/gpt-4o
//   anthropic/claude-sonnet-4-5
if (process.env.CF_AI_GATEWAY_MODEL) {
    const raw = process.env.CF_AI_GATEWAY_MODEL;
    const slashIdx = raw.indexOf('/');
    const gwProvider = raw.substring(0, slashIdx);
    const modelId = raw.substring(slashIdx + 1);

    const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID;
    const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
    const apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY;

    let baseUrl;
    if (accountId && gatewayId) {
        baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + accountId + '/' + gatewayId + '/' + gwProvider;
        if (gwProvider === 'workers-ai') baseUrl += '/v1';
    } else if (gwProvider === 'workers-ai' && process.env.CF_ACCOUNT_ID) {
        baseUrl = 'https://api.cloudflare.com/client/v4/accounts/' + process.env.CF_ACCOUNT_ID + '/ai/v1';
    }

    if (baseUrl && apiKey) {
        const api = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
        const providerName = 'cf-ai-gw-' + gwProvider;

        config.models = config.models || {};
        config.models.providers = config.models.providers || {};
        config.models.providers[providerName] = {
            baseUrl: baseUrl,
            apiKey: apiKey,
            api: api,
            models: [{ id: modelId, name: modelId, contextWindow: 131072, maxTokens: 8192 }],
        };
        config.agents = config.agents || {};
        config.agents.defaults = config.agents.defaults || {};
        config.agents.defaults.model = { primary: providerName + '/' + modelId };
        console.log('AI Gateway model override: provider=' + providerName + ' model=' + modelId + ' via ' + baseUrl);
    } else {
        console.warn('CF_AI_GATEWAY_MODEL set but missing required config (account ID, gateway ID, or API key)');
    }
}

// Telegram configuration
// Overwrite entire channel object to drop stale keys from old R2 backups
// that would fail OpenClaw's strict config validation (see #47)
if (process.env.TELEGRAM_BOT_TOKEN) {
    const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram = {
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        enabled: true,
        dmPolicy: dmPolicy,
    };
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (dmPolicy === 'open') {
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
// openclaw >= 2026.6 uses flat dmPolicy/allowFrom keys (the old nested
// dm.policy shape fails config validation and silently drops the channel).
// The discord channel is also a plugin in >= 2026.6 (installed in the
// Dockerfile) and must be enabled here for the channel to load.
if (process.env.DISCORD_BOT_TOKEN) {
    const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    config.channels.discord = {
        token: process.env.DISCORD_BOT_TOKEN,
        enabled: true,
        dmPolicy: dmPolicy,
    };
    if (dmPolicy === 'open') {
        config.channels.discord.allowFrom = ['*'];
    }
    config.plugins = config.plugins || {};
    config.plugins.entries = config.plugins.entries || {};
    config.plugins.entries.discord = { enabled: true };
}

// Pin the default model. Onboard defaults to the newest Opus, which costs
// ~40% more per token than Sonnet for this workload.
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = { primary: 'anthropic/claude-sonnet-5' };

// Memory search's default embedding provider is OpenAI, which this deployment
// has no key for (Anthropic-only, by design, to keep to a single billing
// relationship). Left unset/"auto", memory-core still tries OpenAI and fails
// with "No API key found for provider openai" on every index/search. Setting
// "none" explicitly opts into full-text-search-only recall (no embedding API,
// no cost) instead of a broken semantic search.
config.agents.defaults.memorySearch = config.agents.defaults.memorySearch || {};
config.agents.defaults.memorySearch.provider = 'none';

// openclaw 2026.6.11's built-in Anthropic catalog predates Claude Sonnet 5,
// so the model must be registered explicitly. models.mode='merge' merges the
// providers MAP, but each provider entry replaces the built-in wholesale —
// an entry carrying only `models` drops api/baseUrl and openclaw falls back
// to its openai-responses transport against api.openai.com, which 401s with
// an Anthropic key. The entry must be a complete provider definition.
config.models = config.models || {};
config.models.mode = 'merge';
config.models.providers = config.models.providers || {};
config.models.providers.anthropic = {
    baseUrl: process.env.ANTHROPIC_BASE_URL || 'https://api.anthropic.com',
    api: 'anthropic-messages',
    models: [
        { id: 'claude-sonnet-5', name: 'Claude Sonnet 5', contextWindow: 1000000, maxTokens: 64000 },
    ],
};
if (process.env.ANTHROPIC_API_KEY) {
    config.models.providers.anthropic.apiKey = process.env.ANTHROPIC_API_KEY;
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = {
        botToken: process.env.SLACK_BOT_TOKEN,
        appToken: process.env.SLACK_APP_TOKEN,
        enabled: true,
    };
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration patched successfully');

// Grant the local CLI device full operator scopes.
// openclaw auto-pairs the CLI with only operator.pairing, but >= 2026.4.21
// the CLI requests broader scopes on connect, and `openclaw devices approve`
// itself can't connect to approve its own upgrade — a documented deadlock
// (openclaw/openclaw#70687, #81555). The Worker's admin API (device approval
// in the Control UI) runs through this CLI, so without this the admin
// console can't approve anything. Re-applied on every container start.
const cliScopes = [
    'operator.admin',
    'operator.approvals',
    'operator.pairing',
    'operator.read',
    'operator.write',
    'operator.talk.secrets',
];
const pairedPath = '/home/openclaw/.openclaw/devices/paired.json';
try {
    if (fs.existsSync(pairedPath)) {
        const paired = JSON.parse(fs.readFileSync(pairedPath, 'utf8'));
        const entries = Array.isArray(paired) ? paired : Object.values(paired);
        let updated = 0;
        for (const dev of entries) {
            if (!dev || (dev.clientId !== 'cli' && dev.clientMode !== 'cli')) continue;
            dev.scopes = cliScopes;
            dev.approvedScopes = cliScopes;
            // tokens is an object keyed by role in 2026.6 (array in older versions)
            const tokens = Array.isArray(dev.tokens) ? dev.tokens : Object.values(dev.tokens || {});
            for (const t of tokens) t.scopes = cliScopes;
            updated++;
        }
        if (updated > 0) {
            fs.writeFileSync(pairedPath, JSON.stringify(paired, null, 2));
            console.log('Granted full operator scopes to ' + updated + ' CLI device(s)');
        }
    }
} catch (e) {
    console.warn('Could not patch CLI device scopes:', e.message);
}
EOFPATCH

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting OpenClaw Gateway..."
echo "Gateway will be available on port 18789"

rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

echo "Dev mode: ${OPENCLAW_DEV_MODE:-false}"

# Gateway token (if set) is already written to openclaw.json by the config
# patch above (gateway.auth.token). We deliberately avoid passing --token on
# the command line because CLI arguments are visible to all processes in the
# container via ps/proc.
if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
else
    echo "Starting gateway with device pairing (no token)..."
fi
exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan
