#!/usr/bin/env bash
# Arcanum Regression Test Suite
#
# Runs unit tests, integration tests against live providers, and examples.
# Sources API keys from .env at the project root (or ARCANUM_ENV_FILE).
# Providers, URLs, and models are hardcoded — env vars are only for secrets.
# Fails fast: stops on the first failure.
#
# Usage:
#   ./test/regression.sh              # run everything
#   ./test/regression.sh --skip-cloud # skip cloud providers (local only)
#   ./test/regression.sh --skip-local # skip local providers (cloud only)
#   ./test/regression.sh --skip-vision      # skip vision tests
#   ./test/regression.sh --skip-image-gen   # skip image generation tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCANUM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ARCANUM_ENV_FILE:-$ARCANUM_DIR/.env}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
SKIP=0

SKIP_CLOUD=false
SKIP_LOCAL=false
SKIP_VISION=false
SKIP_IMAGE_GEN=false

for arg in "$@"; do
  case "$arg" in
    --skip-cloud) SKIP_CLOUD=true ;;
    --skip-local) SKIP_LOCAL=true ;;
    --skip-vision) SKIP_VISION=true ;;
    --skip-image-gen) SKIP_IMAGE_GEN=true ;;
  esac
done

# --- Helpers ---

log()  { echo -e "${CYAN}[regression]${RESET} $*"; }
pass() { echo -e "  ${GREEN}✓${RESET} $*"; PASS=$((PASS + 1)); }
skip() { echo -e "  ${YELLOW}⊘${RESET} $*"; SKIP=$((SKIP + 1)); }

die() {
  echo -e "  ${RED}✗${RESET} $1"
  tail -20 /tmp/arcanum_regression_out | sed 's/^/    /'
  echo ""
  echo -e "${RED}FAILED${RESET}: $1"
  exit 1
}

run_test() {
  local label="$1"
  shift
  if "$@" > /tmp/arcanum_regression_out 2>&1; then
    pass "$label"
  else
    die "$label"
  fi
}

run_example() {
  local label="$1"
  local script="$2"
  shift 2
  if timeout 120 env "$@" elixir "$script" "Reply with exactly: PONG" > /tmp/arcanum_regression_out 2>&1; then
    pass "$label"
  else
    die "$label"
  fi
}

# --- Provider test runners ---

# Runs integration tests + stream example for an OpenAI-compatible provider.
# Args: name base_url api_key model [kind]
run_openai_provider() {
  local name="$1" base_url="$2" api_key="$3" model="$4"
  local kind="${5:-openai}"

  log "$name: $base_url — $model"

  run_test "$name integration ($model)" \
    env ARCANUM_TEST_PROVIDER_URL="$base_url" \
        ARCANUM_TEST_PROVIDER_KEY="$api_key" \
        ARCANUM_TEST_PROVIDER_MODEL="$model" \
        ARCANUM_TEST_PROVIDER_KIND="$kind" \
    mix test --include integration

  run_example "$name example: stream ($model)" \
    examples/stream.exs \
    PROVIDER_BASE_URL="$base_url" \
    PROVIDER_API_KEY="$api_key" \
    PROVIDER_MODEL="$model" \
    PROVIDER_KIND="$kind" \
    PROVIDER_FORMAT=openai
}

# Runs integration tests + stream example for Anthropic.
# Args: name base_url api_key model
run_anthropic_provider() {
  local name="$1" base_url="$2" api_key="$3" model="$4"

  log "$name: $base_url — $model"

  run_test "$name integration ($model)" \
    env ARCANUM_TEST_ANTHROPIC_URL="$base_url" \
        ARCANUM_TEST_ANTHROPIC_KEY="$api_key" \
        ARCANUM_TEST_ANTHROPIC_MODEL="$model" \
    mix test --include anthropic

  run_example "$name example: stream ($model)" \
    examples/stream.exs \
    PROVIDER_BASE_URL="$base_url" \
    PROVIDER_API_KEY="$api_key" \
    PROVIDER_MODEL="$model" \
    PROVIDER_KIND=anthropic \
    PROVIDER_FORMAT=anthropic
}

# Runs integration tests + examples for Ollama.
# Args: base_url model
run_ollama_provider() {
  local base_url="$1" model="$2"

  log "Ollama: $base_url — $model"

  run_test "Ollama integration ($model)" \
    env ARCANUM_TEST_OLLAMA_URL="$base_url" \
        ARCANUM_TEST_OLLAMA_MODEL="$model" \
    mix test --include ollama

  for example in stream tool_call; do
    run_example "Ollama example: $example ($model)" \
      "examples/${example}.exs" \
      PROVIDER_BASE_URL="$base_url" \
      PROVIDER_MODEL="$model" \
      PROVIDER_KIND=ollama \
      PROVIDER_FORMAT=custom
  done
}

# Runs vision test for an OpenAI-compatible provider.
# Args: name base_url api_key model [kind]
run_vision_test() {
  local name="$1" base_url="$2" api_key="$3" model="$4"
  local kind="${5:-openai}"

  run_test "$name vision ($model)" \
    env ARCANUM_TEST_PROVIDER_URL="$base_url" \
        ARCANUM_TEST_PROVIDER_KEY="$api_key" \
        ARCANUM_TEST_PROVIDER_MODEL="$model" \
        ARCANUM_TEST_PROVIDER_KIND="$kind" \
    mix test --include vision
}

# Runs image generation test for an OpenAI-compatible provider.
# Args: name base_url api_key image_model [kind]
run_image_generation_test() {
  local name="$1" base_url="$2" api_key="$3" image_model="$4"
  local kind="${5:-openai}"

  run_test "$name image generation ($image_model)" \
    env ARCANUM_TEST_PROVIDER_URL="$base_url" \
        ARCANUM_TEST_PROVIDER_KEY="$api_key" \
        ARCANUM_TEST_PROVIDER_IMAGE_MODEL="$image_model" \
        ARCANUM_TEST_PROVIDER_KIND="$kind" \
    mix test --include image_generation
}

# Skips a provider when its API key is missing.
# Args: name key_name
skip_if_no_key() {
  local name="$1" key_name="$2"
  if [[ -z "${!key_name:-}" ]]; then
    skip "$name ($key_name not set)"
    return 1
  fi
  return 0
}

# --- Load env (API keys only) ---

if [[ -f "$ENV_FILE" ]]; then
  log "Loading env from $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  log "${YELLOW}Warning: $ENV_FILE not found, cloud tests will be skipped${RESET}"
  SKIP_CLOUD=true
fi

cd "$ARCANUM_DIR"

# ===================================================================
# Phase 1: Unit Tests
# ===================================================================

echo ""
log "${BOLD}Phase 1: Unit Tests${RESET}"

run_test "mix test (unit)" mix test

# ===================================================================
# Phase 2: Local Providers
# ===================================================================

echo ""
log "${BOLD}Phase 2: Local Providers${RESET}"

if [[ "$SKIP_LOCAL" == "true" ]]; then
  skip "Local providers (skipped via --skip-local)"
else
  if curl -sf "http://localhost:11434/api/tags" > /dev/null 2>&1; then
    run_ollama_provider "http://localhost:11434" "gemma4:latest"
  else
    skip "Ollama (not running at localhost:11434)"
  fi
fi

# ===================================================================
# Phase 3: Cloud Providers
# ===================================================================

echo ""
log "${BOLD}Phase 3: Cloud Providers${RESET}"

if [[ "$SKIP_CLOUD" == "true" ]]; then
  skip "All cloud providers (skipped)"
else
  skip_if_no_key "DeepSeek" "DEEPSEEK_KEY" && \
    run_openai_provider "DeepSeek" "https://api.deepseek.com" "$DEEPSEEK_KEY" "deepseek-chat"

  skip_if_no_key "Z.AI" "ZAI_KEY" && \
    run_openai_provider "Z.AI" "https://api.z.ai/api/coding/paas/v4" "$ZAI_KEY" "glm-4.7"

  skip_if_no_key "OpenRouter" "OPENROUTER_KEY" && \
    run_openai_provider "OpenRouter" "https://openrouter.ai/api/v1" "$OPENROUTER_KEY" "meta-llama/llama-3.2-3b-instruct"

  skip_if_no_key "xAI" "XAI_KEY" && \
    run_openai_provider "xAI" "https://api.x.ai/v1" "$XAI_KEY" "grok-3-mini" "xai"

  if [[ "$SKIP_VISION" == "true" ]]; then
    skip "xAI vision (skipped via --skip-vision)"
  else
    skip_if_no_key "xAI" "XAI_KEY" && \
      run_vision_test "xAI" "https://api.x.ai/v1" "$XAI_KEY" "grok-4-fast-non-reasoning" "xai"
  fi

  if [[ "$SKIP_IMAGE_GEN" == "true" ]]; then
    skip "xAI image generation (skipped via --skip-image-gen)"
  else
    skip_if_no_key "xAI" "XAI_KEY" && \
      run_image_generation_test "xAI" "https://api.x.ai/v1" "$XAI_KEY" "grok-imagine-image" "xai"
  fi

  skip_if_no_key "Anthropic" "ANTHROPIC_KEY" && \
    run_anthropic_provider "Anthropic" "https://api.anthropic.com" "$ANTHROPIC_KEY" "claude-sonnet-4-20250514"

  skip_if_no_key "OpenAI" "OPENAPI_KEY" && \
    run_openai_provider "OpenAI" "https://api.openai.com/v1" "$OPENAPI_KEY" "gpt-4.1-nano"

  if [[ "$SKIP_VISION" == "true" ]]; then
    skip "OpenAI vision (skipped via --skip-vision)"
  else
    skip_if_no_key "OpenAI" "OPENAPI_KEY" && \
      run_vision_test "OpenAI" "https://api.openai.com/v1" "$OPENAPI_KEY" "gpt-4.1-nano"
  fi

  if [[ "$SKIP_IMAGE_GEN" == "true" ]]; then
    skip "OpenAI image generation (skipped via --skip-image-gen)"
  else
    skip_if_no_key "OpenAI" "OPENAPI_KEY" && \
      run_image_generation_test "OpenAI" "https://api.openai.com/v1" "$OPENAPI_KEY" "gpt-image-1"
  fi
fi

# ===================================================================
# Summary
# ===================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BOLD}Regression Summary${RESET}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ${GREEN}Passed:${RESET}  $PASS"
echo -e "  ${YELLOW}Skipped:${RESET} $SKIP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}ALL PASSED${RESET}"
echo ""
exit 0
