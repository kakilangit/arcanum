# Contributing: Adding Providers and Models

This guide explains how to integrate a new provider or add models to an existing provider in Arcanum.

## Architecture Overview

Arcanum uses a two-layer architecture:

- **Adapters** handle the wire protocol (OpenAI-compatible or Anthropic format)
- **Model profiles** declare capabilities upfront — no runtime detection

Most new providers use the OpenAI-compatible API format and don't need a new adapter. You only need to register the provider and configure its models via overlays.

## Adding a New Provider

### 1. Determine the API Format

Arcanum has three adapters:

| Adapter | Use When |
|---------|----------|
| `openai` | Provider implements the OpenAI chat completions API (`/v1/chat/completions`) |
| `anthropic` | Provider implements the Anthropic messages API (`/v1/messages`) |
| `ollama` | Provider implements the Ollama API (`/api/chat`) |

If the provider uses the OpenAI-compatible format (most do), no adapter code is needed.

### 2. Register in the Model Profile Registry

If the provider is listed on [models.dev](https://models.dev), add its kind to `@default_providers` in `lib/arcanum/model_profile/registry.ex`:

```elixir
@default_providers [
  "openai",
  "anthropic",
  "deepseek",
  # ... existing providers
  "new-provider"    # must match the models.dev provider ID
]
```

This enables automatic model profile fetching from models.dev. For local-only providers not on models.dev (e.g., Ollama), add a provider default in `priv/overlays.json` instead (see step 3).

### 3. Add Overlays

Add model-specific capability overrides in `priv/overlays.json`. Overlays supplement or override what models.dev provides.

```json
{
  "overlays": {
    "new-provider": {
      "model-with-vision": { "supports_vision": true },
      "reasoning-model": {
        "thinking_param": { "type": "enabled" },
        "preserve_reasoning": true
      }
    }
  }
}
```

#### Available Overlay Fields

| Field | Type | Purpose |
|-------|------|---------|
| `supports_vision` | boolean | Model accepts image content blocks |
| `supports_tools` | boolean | Model supports native tool/function calling |
| `tool_call_format` | `"native"` or `"xml_text"` | How tool calls are formatted |
| `thinking_param` | object | Enables reasoning/thinking mode (`{ "type": "enabled" }`) |
| `preserve_reasoning` | boolean | Keep reasoning content in response |
| `uses_max_completion_tokens` | boolean | Use `max_completion_tokens` instead of `max_tokens` |
| `supports_image_generation` | boolean | Model generates images |
| `supported_sizes` | list | Valid image sizes (e.g., `["1024x1024"]`) |
| `supported_formats` | list | Valid image formats (e.g., `["png", "webp"]`) |
| `supported_qualities` | list | Valid quality levels |
| `supports_style` | boolean | Model accepts style parameter |
| `image_response_mode` | `"native_b64"` or `"request_b64"` | How image data is returned |
| `max_outputs_per_request` | integer | Max images per request |
| `max_context` | integer | Context window size |

#### Provider Defaults

For local providers not in models.dev, add a fallback profile under `provider_defaults`:

```json
{
  "provider_defaults": {
    "local-provider": {
      "supports_system_role": true,
      "supports_tools": false,
      "tool_call_format": "xml_text",
      "max_context": 32768
    }
  }
}
```

### 4. Add Regression Tests

Add the provider to `test/regression.sh`. Each provider needs:

1. **Hardcoded URL, model, and kind** at the top of the script (env vars are only for API keys)
2. **Integration test block** that sets `ARCANUM_TEST_OPENAI_*` env vars and runs `mix test --include integration`
3. **Example script run** using `examples/stream.exs`

```bash
# At the top — provider config
NEW_PROVIDER_BASE_URL="https://api.new-provider.com/v1"
NEW_PROVIDER_MODEL="their-model"

# In Phase 3 — test block
if [[ -n "${NEW_PROVIDER_KEY:-}" ]]; then
  log "NewProvider: $NEW_PROVIDER_BASE_URL — $NEW_PROVIDER_MODEL"

  run_test "NewProvider integration ($NEW_PROVIDER_MODEL)" \
    env ARCANUM_TEST_OPENAI_URL="$NEW_PROVIDER_BASE_URL" \
        ARCANUM_TEST_OPENAI_KEY="$NEW_PROVIDER_KEY" \
        ARCANUM_TEST_OPENAI_MODEL="$NEW_PROVIDER_MODEL" \
    mix test --include integration

  run_example "NewProvider example: stream ($NEW_PROVIDER_MODEL)" \
    examples/stream.exs \
    PROVIDER_BASE_URL="$NEW_PROVIDER_BASE_URL" \
    PROVIDER_API_KEY="$NEW_PROVIDER_KEY" \
    PROVIDER_MODEL="$NEW_PROVIDER_MODEL" \
    PROVIDER_KIND=openai \
    PROVIDER_FORMAT=openai
else
  skip "NewProvider (NEW_PROVIDER_KEY not set)"
fi
```

For Anthropic-format providers, use `--include anthropic` and set `ARCANUM_TEST_ANTHROPIC_*` vars instead.

### 5. Add API Key to `.env`

Add the provider's API key to the root `.env` file:

```
NEW_PROVIDER_KEY=sk-...
```

### 6. Update Documentation

- Add the provider to the **Supported Providers** table in `README.md`
- Add the provider to the description in `mix.exs`

## Adding Models to an Existing Provider

When a provider releases new models:

1. **Add overlays** in `priv/overlays.json` if the model has capabilities not covered by models.dev (vision, reasoning, image generation)
2. **Verify** by running the regression suite: `./test/regression.sh`

No code changes are needed for standard chat/stream/tool models — the Registry fetches capabilities from models.dev automatically.

## Writing a New Adapter

Only needed when a provider uses a non-standard API format (not OpenAI or Anthropic compatible).

1. Implement the `Arcanum.Provider` behaviour (`use Arcanum.Provider`)
2. Add the adapter module under `lib/arcanum/adapters/`
3. Register the format in `Arcanum.Gateway` routing
4. Add integration tests with a dedicated ExUnit tag
5. Add a describe block in `test/integration/provider_test.exs`

## Verification Checklist

Before submitting changes:

- [ ] `make lint` passes (zero warnings, Credo strict)
- [ ] `make test` passes (unit tests)
- [ ] `./test/regression.sh` passes (integration + examples against live providers)
- [ ] New provider appears in the README Supported Providers table
- [ ] Overlays are minimal — only override what models.dev doesn't provide
