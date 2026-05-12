# Arcanum

Provider-agnostic AI inference library for Elixir.

## Overview

Arcanum provides a unified interface for chat completion, streaming, embeddings, and tool use across multiple AI providers. Model capabilities are declared upfront via profiles — no runtime detection or error-code fallbacks.

## Supported Providers

| Provider | API Format | Features |
|----------|-----------|----------|
| Anthropic | Anthropic | Chat, stream, tools |
| DeepSeek | OpenAI | Chat, stream, tools |
| GitHub Copilot | OpenAI | Chat, stream, tools (OAuth device flow) |
| OpenRouter | OpenAI | Chat, stream, tools |
| ZAI / Zhipu | OpenAI | Chat, stream, tools |
| LM Studio | OpenAI | Chat, stream, tools (auto model loading) |

## Installation

```elixir
def deps do
  [
    {:arcanum, "~> 0.1.0"}
  ]
end
```

## Usage

All inference goes through `Arcanum.Gateway`:

```elixir
provider = %{
  base_url: "https://api.openai.com",
  api_key: "sk-...",
  kind: "openai",
  api_format: :openai
}

intent = %Arcanum.Intent{
  model: "gpt-4o",
  messages: [%{role: :user, content: "Hello"}]
}

# Synchronous
{:ok, %Arcanum.Response{content: content}} = Arcanum.Gateway.chat(provider, intent)

# Streaming
{:ok, stream} = Arcanum.Gateway.stream(provider, intent)

# List models
{:ok, models} = Arcanum.Gateway.list_models(provider)

# Embeddings (OpenAI, Ollama)
{:ok, %Arcanum.Response{}} = Arcanum.Gateway.embed(provider, intent)
```

### Tool Use

Pass tools in the intent. Arcanum handles native, XML-text, and JSON-text tool call formats transparently based on the model profile.

```elixir
intent = %Arcanum.Intent{
  model: "gpt-4o",
  messages: [%{role: :user, content: "What is the weather in Berlin?"}],
  tools: [
    %{
      type: "function",
      function: %{
        name: "get_weather",
        description: "Get current weather",
        parameters: %{
          type: "object",
          properties: %{location: %{type: "string"}},
          required: ["location"]
        }
      }
    }
  ]
}

{:ok, %Arcanum.Response{tool_calls: tool_calls}} = Arcanum.Gateway.chat(provider, intent)
```

## Architecture

```
Gateway (public entry point)
  -> Auth resolution (API key, Copilot OAuth)
  -> Adapter dispatch (OpenAI, Anthropic, Ollama)
  -> Response normalization (profile-driven post-processing)
```

- **`Arcanum.Gateway`** — single entry point for all inference calls
- **`Arcanum.Intent`** — canonical request struct
- **`Arcanum.Response`** — canonical response struct
- **`Arcanum.ModelProfile`** — declares model capabilities (tools, system role, reasoning, context length)
- **`Arcanum.ModelProfile.Registry`** — ETS cache backed by [models.dev](https://models.dev), refreshed hourly
- **`Arcanum.Response.Normalizer`** — profile-driven post-processing (content fallback, think-tag stripping, tool call extraction)
- **`Arcanum.Probe`** — TCP availability check for local providers
- **`Arcanum.EnsureModel`** — pre-loads models on LM Studio before inference
- **`Arcanum.Auth.Copilot`** — GitHub Copilot OAuth device code flow (RFC 8628)

## Configuration

```elixir
# Required for GitHub Copilot
config :arcanum, copilot_client_id: "your-client-id"

# Optional: custom HTTP client (defaults to Req)
config :arcanum, http_client: MyCustomClient
```

## Design Principles

- **Profile-driven.** Model capabilities are declared upfront, never discovered via error codes.
- **Everything has a limit.** Retries, timeouts, model counts, poll attempts — all bounded.
- **Callers never touch adapters directly.** Gateway is the only public interface.
- **Two-layer separation.** Adapters handle wire protocol. Normalizer handles model-specific post-processing.

## License

MIT