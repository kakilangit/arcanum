# Arcanum

Provider-agnostic AI inference library for Elixir.

## Overview

Arcanum provides a unified interface for chat completion, streaming, embeddings, tool use, and media generation across multiple AI providers. Model capabilities are declared upfront via profiles — no runtime detection or error-code fallbacks.

## Supported Providers

| Provider | API Format | Features |
|----------|-----------|----------|
| OpenAI | OpenAI | Chat, stream, tools, vision, image generation, embeddings |
| Anthropic | Anthropic | Chat, stream, tools, vision |
| Ollama | Ollama | Chat, stream, tools, vision, embeddings |
| Grimoire | Grimoire | Chat, stream, model listing (plugin-based providers) |
| DeepSeek | OpenAI | Chat, stream, tools |
| GitHub Copilot | OpenAI | Chat, stream, tools, vision (OAuth device flow) |
| OpenRouter | OpenAI | Chat, stream, tools |
| xAI (Grok) | OpenAI | Chat, stream, tools, vision, image generation |
| ZAI / Zhipu | OpenAI | Chat, stream, tools |

## Installation

```elixir
def deps do
  [
    {:arcanum, "~> 0.1.4"}
  ]
end
```

## Usage

All inference goes through `Arcanum.Gateway`. Callers never touch adapters directly.

### Provider Map

Every Gateway function takes a provider map describing the endpoint:

```elixir
provider = %{
  base_url: "https://api.openai.com",
  api_key: "sk-...",
  kind: "openai",
  api_format: :openai,
  type: :cloud
}
```

| Key | Type | Description |
|-----|------|-------------|
| `base_url` | `String.t()` | Required. Provider API base URL. |
| `api_key` | `String.t() \| nil` | API key. Not needed for local providers or Copilot. |
| `api_format` | `:openai \| :anthropic \| :grimoire \| :custom` | Determines which adapter handles the request. |
| `kind` | `String.t()` | Provider ID (e.g. `"openai"`, `"anthropic"`, `"ollama"`, `"github-copilot"`). Used for profile resolution and provider-specific behavior. |
| `type` | `:cloud \| :local` | Used by `Arcanum.Probe` to skip TCP checks for cloud providers. |
| `extra_headers` | `[{String.t(), String.t()}] \| nil` | Additional HTTP headers (injected automatically for Copilot). |

### Chat Completion

```elixir
alias Arcanum.{Gateway, Intent}

intent = %Intent{
  model: "gpt-4o",
  messages: [
    %{role: :system, content: Intent.text("You are a helpful assistant.")},
    %{role: :user, content: Intent.text("What is Elixir?")}
  ],
  temperature: 0.7,
  max_tokens: 1024
}

{:ok, response} = Gateway.chat(provider, intent)
text = Arcanum.Response.text(response)
```

### Streaming

```elixir
{:ok, stream} = Gateway.stream(provider, intent)

Enum.each(stream, fn
  {:data, %Arcanum.Response{} = response} ->
    IO.write(Arcanum.Response.text(response) || "")
  :done -> IO.puts("\n--- done ---")
  {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
end)
```

### Tool Use

Pass tools in the intent. Arcanum handles native, XML-text, and JSON-text tool call formats transparently based on the model profile.

```elixir
intent = %Intent{
  model: "gpt-4o",
  messages: [%{role: :user, content: Intent.text("What is the weather in Berlin?")}],
  tools: [
    %{
      type: "function",
      function: %{
        name: "get_weather",
        description: "Get current weather for a location",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "location" => %{"type" => "string", "description" => "City name"}
          },
          "required" => ["location"]
        }
      }
    }
  ]
}

{:ok, %Arcanum.Response{tool_calls: tool_calls}} = Gateway.chat(provider, intent)

# tool_calls is a list of:
# %{id: "call_abc", function: %{name: "get_weather", arguments: "{\"location\":\"Berlin\"}"}}
```

Models that don't support native tool calls (e.g. some Ollama models) automatically get XML-text or JSON-text extraction based on their profile's `tool_call_format`.

### Vision (Multimodal)

```elixir
intent = %Intent{
  model: "gpt-4o",
  messages: [
    %{role: :user, content: [
      %{type: :text, text: "What's in this image?"},
      %{type: :image_url, url: "https://example.com/photo.jpg"}
    ]}
  ]
}

# Or with base64:
%{type: :image_base64, media_type: "image/png", data: "iVBOR..."}
```

### Embeddings

```elixir
{:ok, embeddings} = Gateway.embed(provider, "gpt-4o", "Hello world")
# embeddings is a list of floats
```

Supported by OpenAI and Ollama adapters. Returns `{:error, :not_supported}` for adapters that don't override the default.

### Image Generation

```elixir
alias Arcanum.{Gateway, Intent}

intent = %Intent{
  model: "gpt-image-1",
  prompt: "A cat wearing a wizard hat",
  size: "1024x1024",
  quality: "auto",
  n: 1,
  format: "png"
}

{:ok, %Arcanum.Response{content: [%{type: :image} = image | _]}} =
  Gateway.generate_image(provider, intent)

# image fields:
#   data: binary()          — decoded image bytes (from b64_json)
#   url: String.t() | nil   — image URL (if provider returns one)
#   revised_prompt: String.t() | nil
#   content_type: "image/png"
```

Image generation parameters (`size`, `quality`, `style`) are profile-driven — only sent when the model's overlay declares support via `supported_sizes`, `supported_qualities`, or `supports_style`.

### List Models

```elixir
{:ok, models} = Gateway.list_models(provider)
# ["gpt-4o", "gpt-4o-mini", "gpt-4.1", ...]
```

### Probe Availability

```elixir
Arcanum.Probe.probe_provider(provider)
# :online | :offline
```

Cloud providers always return `:online`. Local providers get a TCP connect check (2s timeout).

### GitHub Copilot Authentication

```elixir
alias Arcanum.Auth.Copilot

# 1. Start device flow
{:ok, flow} = Copilot.start_device_flow()
# flow.verification_uri -> "https://github.com/login/device"
# flow.user_code -> "ABCD-1234"

# 2. User visits URL and enters code, then:
{:ok, access_token} = Copilot.poll_for_token(flow)

# 3. Use the token as the provider's api_key
provider = %{
  base_url: Copilot.base_url(),
  api_key: access_token,
  kind: "github-copilot",
  api_format: :openai,
  type: :cloud,
  extra_headers: Copilot.copilot_headers(access_token)
}
```

For non-blocking flows, use `Copilot.poll_once/1` for single-attempt polling (e.g. from an Oban job).

## Configuration

### Application Config

```elixir
# Required for GitHub Copilot OAuth
config :arcanum, copilot_client_id: "your-github-oauth-client-id"

# Optional: override HTTP client (defaults to Req)
config :arcanum, http_client: MyCustomClient
```

### Model Profile System

Every model gets a `ModelProfile` that declares its capabilities upfront. Profiles drive serialization, normalization, and feature gating — the adapter never guesses.

```elixir
%Arcanum.ModelProfile{
  supports_system_role:      true,       # can the model accept system messages?
  supports_tools:            true,       # native tool call support?
  supports_vision:           false,      # multimodal image input?
  supports_image_generation: false,      # image generation capability?
  supports_video_generation: false,      # video generation capability?
  tool_call_format:          :native,    # :native | :xml_text
  reasoning_field:           nil,        # atom — where the model puts thinking (e.g. :reasoning_content)
  thinking_param:            nil,        # map sent to provider to enable thinking (e.g. %{type: "enabled"})
  preserve_reasoning:        false,      # keep thinking content in response?
  uses_max_completion_tokens: false,     # use max_completion_tokens instead of max_tokens?
  max_context:               131_072,    # maximum context window
  max_images_per_message:    4,          # vision: max images per message
  max_outputs_per_request:   4,          # media generation: max outputs
  supported_sizes:           [],         # media generation: allowed dimensions
  supported_formats:         [],         # media generation: allowed formats
  supported_qualities:       [],         # media generation: allowed quality levels
  supports_style:            false,      # media generation: accepts style parameter
  image_response_mode:       nil,        # :native_b64 | :request_b64
  provider_routing:          nil         # provider-specific routing metadata
}
```

### Profile Resolution

Profiles are resolved automatically by `Gateway` via `Arcanum.ModelProfile.Resolver`. Resolution follows a strict priority chain:

```
1. User overrides     (highest — caller-provided fields)
2. Overlay            (provider/model-specific, from priv/overlays.json)
3. Registry           (models.dev cache — single source of truth)
4. Provider default   (fallback for local providers not in models.dev)
5. Global default     (lowest — assumes weakest capabilities)
```

#### Registry (models.dev)

The `Arcanum.ModelProfile.Registry` GenServer fetches model capabilities from [models.dev](https://models.dev) and caches them in ETS. Refreshes hourly. Falls back gracefully if the fetch fails.

Default providers fetched: `openai`, `anthropic`, `deepseek`, `openrouter`, `xai`, `zai`, `zhipuai`, `github-copilot`.

```elixir
# Lookup a cached profile (returns nil if not found)
Arcanum.ModelProfile.Registry.lookup("openai", "gpt-4o")

# List all cached provider IDs
Arcanum.ModelProfile.Registry.cached_providers()
```

#### Overlays (`priv/overlays.json`)

Overlays patch capabilities that models.dev doesn't track (vision, image generation, reasoning params). They are compiled into the Resolver at build time.

```json
{
  "overlays": {
    "openai": {
      "gpt-4o": { "supports_vision": true },
      "gpt-image-1": {
        "supports_image_generation": true,
        "supported_sizes": ["1024x1024", "1024x1536", "1536x1024", "auto"],
        "supported_formats": ["png", "webp", "jpeg"],
        "max_outputs_per_request": 4
      }
    },
    "deepseek": {
      "deepseek-r1": { "preserve_reasoning": true }
    }
  },
  "provider_defaults": {
    "ollama": {
      "supports_system_role": true,
      "supports_tools": false,
      "tool_call_format": "xml_text",
      "max_context": 32768
    }
  }
}
```

#### Provider Defaults

For local providers not in models.dev (Ollama), provider defaults from `priv/overlays.json` are used as the base profile. These assume conservative capabilities.

#### Profile Overrides

Callers can override any profile field at call time via the `:profile_overrides` option. Overrides take the highest priority in the resolution chain.

```elixir
# Force a model to use XML text tool calls
Gateway.chat(provider, intent, profile_overrides: %{tool_call_format: :xml_text})

# Override context window for a specific call
Gateway.chat(provider, intent, profile_overrides: %{max_context: 65_536})

# Enable vision for a model not in the registry
Gateway.chat(provider, intent, profile_overrides: %{supports_vision: true})

# Multiple overrides
Gateway.chat(provider, intent,
  profile_overrides: %{
    supports_tools: false,
    tool_call_format: :xml_text,
    max_context: 16_384
  }
)
```

Any field from `ModelProfile` can be overridden. The override map is merged on top of the resolved profile, so you only need to specify the fields you want to change.

### Gateway Options

All `Gateway.chat/3` and `Gateway.stream/3` calls accept an opts keyword list:

| Option | Type | Description |
|--------|------|-------------|
| `:profile_overrides` | `map()` | Override any `ModelProfile` fields for this call. |
| `:adapter` | `module()` | Override the adapter module (useful for testing). |

## Architecture

```
Gateway (single public entry point)
  -> Auth resolution (API key, Copilot OAuth headers)
  -> Profile resolution (Resolver: overrides > overlay > registry > provider default > global default)
  -> Adapter dispatch (OpenAI, Anthropic, Ollama)
  -> Response normalization (Normalizer: content fallback, think-tag stripping, tool-call extraction)
```

### Core Modules

| Module | Purpose |
|--------|---------|
| `Arcanum.Gateway` | Single entry point for all inference calls. |
| `Arcanum.Intent` | Canonical request struct for chat, streaming, and media generation. Content is always `[content_block()]`. |
| `Arcanum.Response` | Canonical response struct (content, thinking, tool_calls, usage). Also used for image generation results. |
| `Arcanum.ModelProfile` | Declares model capabilities (tools, vision, reasoning, context, image gen params). |
| `Arcanum.ModelProfile.Resolver` | Multi-layer profile resolution with override support. |
| `Arcanum.ModelProfile.Registry` | ETS cache backed by models.dev, refreshed hourly. |
| `Arcanum.Response.Normalizer` | Profile-driven post-processing (XML/JSON tool extraction, think tags). |
| `Arcanum.Provider` | Behaviour + macro (`use Arcanum.Provider`) with defoverridable defaults. |
| `Arcanum.Probe` | TCP availability check for local providers. |
| `Arcanum.Auth.Copilot` | GitHub Copilot OAuth device code flow (RFC 8628). |

### Shared Infrastructure

| Module | Purpose |
|--------|---------|
| `Arcanum.HTTP` | Configurable HTTP client, URL construction, async body draining (10 MB limit). |
| `Arcanum.Retry` | Generic retry wrapper with exponential backoff (2s base, 30s cap, 3 attempts). |
| `Arcanum.SSE` | Callback-driven Server-Sent Events stream parsing with configurable done sentinel. |

### Adapters

| Adapter | Behaviour Callbacks |
|---------|-------------------|
| `Arcanum.Adapters.OpenAI` | `chat`, `stream`, `list_models`, `embed`, `generate_image` |
| `Arcanum.Adapters.Anthropic` | `chat`, `stream`, `list_models` |
| `Arcanum.Adapters.Ollama` | `chat`, `stream`, `list_models`, `embed` |
| `Arcanum.Adapters.Grimoire` | `chat`, `stream`, `list_models` |

### Error Handling

All Gateway functions return `{:ok, result}` or `{:error, reason}`. Error shapes:

| Error | Meaning |
|-------|---------|
| `{:error, {:api_error, status, body}}` | HTTP error from the provider. |
| `{:error, {:api_error, :max_retries_exceeded}}` | All retry attempts exhausted. |
| `{:error, :context_overflow}` | Input exceeded the model's context window. |
| `{:error, :not_supported}` | Adapter doesn't implement the requested callback. |
| `{:error, :copilot_auth_required}` | Copilot provider needs OAuth authentication. |
| `{:error, term()}` | Network or other transient errors. |

Transient HTTP errors (429, 502, 503, 529) are retried automatically up to 3 times with exponential backoff via `Arcanum.Retry`.

## Development

```sh
make deps       # fetch dependencies
make lint       # format + credo --strict + compile --warnings-as-errors
make test       # unit tests
make regression # full regression suite (unit + integration + examples)
```

The regression script supports flags:

```sh
./test/regression.sh --skip-cloud     # local providers only
./test/regression.sh --skip-local     # cloud providers only
./test/regression.sh --skip-vision    # skip vision tests
./test/regression.sh --skip-image-gen # skip image generation tests
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to add new providers and models.

## License

MIT
