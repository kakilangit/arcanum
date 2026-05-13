# Contributing: Adding Providers and Models

This guide explains how to integrate a new provider or add models to an existing provider in Arcanum.

## Architecture Overview

Arcanum uses a two-layer architecture:

- **Adapters** handle the wire protocol (OpenAI-compatible or Anthropic format)
- **Model profiles** declare capabilities upfront — no runtime detection
- **Shared modules** (`Arcanum.HTTP`, `Arcanum.Retry`, `Arcanum.SSE`) provide common HTTP, retry, and SSE parsing logic — adapters delegate to these instead of duplicating

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
2. **Integration test block** that sets `ARCANUM_TEST_PROVIDER_*` env vars and runs `mix test --include integration`
3. **Example script run** using `examples/stream.exs`

```bash
# In Phase 3 — use the reusable provider test runners
skip_if_no_key "NewProvider" "NEW_PROVIDER_KEY" && \
  run_openai_provider "NewProvider" "https://api.new-provider.com/v1" "$NEW_PROVIDER_KEY" "their-model"

# For vision-capable models (guarded by --skip-vision):
if [[ "$SKIP_VISION" != "true" ]]; then
  skip_if_no_key "NewProvider" "NEW_PROVIDER_KEY" && \
    run_vision_test "NewProvider" "https://api.new-provider.com/v1" "$NEW_PROVIDER_KEY" "their-vision-model"
fi

# For image generation models (guarded by --skip-image-gen):
if [[ "$SKIP_IMAGE_GEN" != "true" ]]; then
  skip_if_no_key "NewProvider" "NEW_PROVIDER_KEY" && \
    run_image_generation_test "NewProvider" "https://api.new-provider.com/v1" "$NEW_PROVIDER_KEY" "their-image-model"
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
2. **Verify** by running the regression suite: `make regression` (or `./test/regression.sh`)

Use `--skip-vision` and/or `--skip-image-gen` to skip those test categories:

```bash
./test/regression.sh --skip-vision --skip-image-gen
```

No code changes are needed for standard chat/stream/tool models — the Registry fetches capabilities from models.dev automatically.

## Writing a New Adapter

Only needed when a provider uses a non-standard API format (not OpenAI or Anthropic compatible).

1. Implement the `Arcanum.Provider` behaviour (`use Arcanum.Provider`)
2. Use `Arcanum.HTTP` for HTTP client access and URL construction
3. Use `Arcanum.Retry` for retry logic (or implement custom retry via `Retry.with_retry/2`)
4. Use `Arcanum.SSE` for SSE stream parsing if the provider uses SSE
5. Add the adapter module under `lib/arcanum/adapters/`
6. Register the format in `Arcanum.Gateway` routing
7. Add integration tests with a dedicated ExUnit tag
8. Add a describe block in `test/integration/provider_test.exs`

## Verification Checklist

Before submitting changes:

- [ ] `make lint` passes (zero warnings, Credo strict)
- [ ] `make test` passes (unit tests)
- [ ] `make regression` passes (integration + examples against live providers)
- [ ] New provider appears in the README Supported Providers table
- [ ] Overlays are minimal — only override what models.dev doesn't provide
