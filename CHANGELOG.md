# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.2] - 2026-05-13

### Changed

- **Unified content blocks**: `Intent.content` and `Response.content` are always `[content_block()]`. Bare string content is no longer accepted — callers must use `Intent.text/1` to wrap text. `Response.text/1` helper extracts text from content blocks.
- **Provider behaviour**: `use Arcanum.Provider` macro replaces `@behaviour` + `@optional_callbacks`. Optional callbacks (`embed/3`, `generate_image/3`, `generate_video/3`) now have `defoverridable` default implementations returning `{:error, :not_supported}`. Adapters override only what they support.
- **Gateway**: Direct adapter dispatch replaces `apply/3` + `function_exported?` runtime detection. No runtime capability checks — capabilities are declared statically at compile time.

### Added

- **Overlay system**: Profile-driven image generation params (`supported_qualities`, `supports_style`, `image_response_mode`) with overlays for gpt-image-1, dall-e-3, dall-e-2, grok-2-image
- **Media generation**: `MediaIntent` / `MediaResponse` structs and `Gateway.generate_image/3` / `Gateway.generate_video/3` functions
- **ModelProfile fields**: `uses_max_completion_tokens` flag for newer OpenAI models
- **Ollama adapter**: Multimodal (vision) support
- **Resolver**: Generic overlay resolution with nested provider→model map structure
- **Regression test suite**: Data-driven `test/regression.sh` with reusable provider test runners (`run_openai_provider`, `run_anthropic_provider`, `run_ollama_provider`). Fail-fast. Providers/models hardcoded — env vars only for API keys.
- **CONTRIBUTING.md**: Provider and model integration guide with overlay reference, regression test template, and verification checklist

### Fixed

- **Streaming delta merge**: `merge_content_blocks/2` coalesces consecutive text blocks during streaming
- **Ollama tool calls**: `decode_arguments/1` handles Ollama returning `arguments` as a map instead of a JSON string
- **Copilot test isolation**: `on_exit` cleanup now resets both `:copilot_client_id` and `:http_client` application env to prevent stub leaks into integration tests

### Removed

- **LM Studio support**: Removed provider, `EnsureModel` module, registry entry, overlays, and probe logic. Unreliable compute errors and 4096 context window limitations.
- **vLLM support**: Removed provider from registry, overlays, and documentation. No verification infrastructure available.

## [0.1.1] - 2026-05-12

### Fixed

- **Anthropic adapter**: Rewrite message formatting for correct Anthropic wire protocol
  - System prompt extraction now handles both atom (`:system`) and string (`"system"`) roles
  - Messages formatted with only `"user"` and `"assistant"` roles (Anthropic requirement)
  - Tool results sent as `"user"` role with `tool_result` content blocks (not `role: "tool"`)
  - Assistant tool calls sent as `tool_use` content blocks (not `tool_calls` key)
  - Adjacent same-role messages merged automatically (alternating role requirement)
  - Mid-conversation system messages injected as user messages with `[System]` prefix

### Added

- **Anthropic adapter**: Retry logic with bounded exponential backoff (429, 502, 503, 529)
- **Anthropic adapter**: Streaming support for `thinking_delta`, `input_json_delta`, `content_block_start` events
- **Anthropic adapter**: Async body draining for error responses (matches OpenAI adapter)
- **Anthropic unit tests**: 14 tests covering system extraction, message formatting, tool definitions, response parsing, headers, URL construction
- **README**: Anthropic added back to supported providers table
- **README**: Comprehensive rewrite covering usage, configuration, profile resolution, and profile overrides

## [0.1.0] - 2026-05-12

### Added

- **Gateway API**: Single entry point (`Arcanum.Gateway`) for chat, streaming, embeddings, and model listing across all providers
- **Provider adapters**: OpenAI, Anthropic, and Ollama adapters with unified request/response normalization
- **OpenAI-compatible providers**: DeepSeek, GitHub Copilot, OpenRouter, xAI (Grok), Z.AI/Zhipu — all route through the OpenAI adapter
- **Streaming support**: Chunked SSE streaming with delta merging for content and tool calls
- **Tool use**: Native, XML-text, and JSON-text tool call formats, transparently selected per model profile
- **Model Profile Registry**: ETS-cached model capabilities from [models.dev](https://models.dev), refreshed hourly with bounded retry
- **Profile-driven normalization**: `Arcanum.Response.Normalizer` handles content fallback, think-tag stripping, reasoning extraction, and tool call parsing based on declared model capabilities
- **Overlay system**: `priv/overlays.json` for provider/model-specific overrides (thinking_param, preserve_reasoning, provider_routing) not covered by models.dev
- **Provider-level defaults**: Fallback profiles for local providers (Ollama) when models aren't in the registry
- **GitHub Copilot auth**: OAuth device code flow (RFC 8628) with token caching and automatic refresh
- **Local provider probing**: `Arcanum.Probe` TCP availability check for Ollama
- **Structured errors**: Two-layer error tuples (`{:error, {:api_error, status, body}}`) — no opaque structs leak across boundaries
- **Bounded everything**: Retries, timeouts, poll attempts, model counts, registry refresh — all have explicit upper limits
- **README**: Full library overview, usage examples, architecture diagram, and design principles

### Fixed

- **Streaming tool call merge**: Separate `parse_tool_call_deltas/1` preserves `index` field and defaults arguments to `""` for proper concatenation across delta fragments
- **Async body drain**: Streaming errors drain the `Req.Response.Async` body at the adapter layer — callers never receive opaque structs
- **Base URL handling**: Strips trailing `/v1` before appending API paths, correctly handles versioned paths (Z.AI `/v4`)

[Unreleased]: https://github.com/kakilangit/arcanum/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/kakilangit/arcanum/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/kakilangit/arcanum/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/kakilangit/arcanum/releases/tag/v0.1.0
