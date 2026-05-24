# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.10] - 2026-05-24

### Changed

- `Retry.with_retry/2` now logs each retry attempt with HTTP status, body, and backoff delay
- Final exhaustion error changed from `{:api_error, :max_retries_exceeded}` to `{:api_error, :max_retries_exceeded, last_status, last_body}` — carries the last HTTP status and response body

## [0.1.9] - 2026-05-24

### Added

- `temperature_not_supported` model profile field — adapters strip temperature from requests when set
- Overlays for OpenAI models: `gpt-5`, `gpt-5-nano`, `gpt-5.2`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.4-nano`, `gpt-5.5` with `uses_max_completion_tokens`
- Temperature stripping for reasoning models: `gpt-5`, `gpt-5-mini`, `gpt-5-nano`, `gpt-5.5`, `o1`, `o3`, `o3-mini`, `o4-mini`, `claude-opus-4-7`
- Overlays for xAI `grok-4.20-0309-non-reasoning` and `grok-4.20-0309-reasoning`

## [0.1.8] - 2026-05-24

### Added

- Model verification scripts (`test/verify_models.exs`, `test/list_models.exs`) for comprehensive multi-provider testing
  - Tests chat, tool_call, and streaming capabilities per model
  - Supports `--provider` filter for targeted runs
  - Reports pass/fail matrix with failure details and summary

## [0.1.7] - 2026-05-24

### Fixed

- Add `gpt-5-mini` overlay with `uses_max_completion_tokens: true`

## [0.1.6] - 2026-05-24

### Fixed

- Add `deepseek-v4-pro` to overlays with `preserve_reasoning: true` — fixes reasoning_content passback error

## [0.1.5] - 2026-05-24

### Fixed

- xAI Grok models now use `max_completion_tokens` instead of `max_tokens`

## [0.1.4] - 2026-05-23

### Added

- **Grimoire adapter**: First-class `:grimoire` api_format for plugin-based inference providers
  - `GET {base_url}/models` with context in `X-Plugin-Context` header (base64-encoded JSON)
  - `POST {base_url}/chat` with context in request body, streaming via SSE
  - `list_models/2`, `chat/4`, `stream/4` callbacks
- **`adapter_for/1`**: Routes `:grimoire` api_format to `Arcanum.Adapters.Grimoire`
- **`Probe`**: Skips TCP probe for grimoire providers (container availability managed externally)

## [0.1.3] - 2026-05-20

### Fixed

- **`adapter_for/1` atom kind matching**: All `kind` and `api_format` guards now accept both atoms and strings. Fixes adapter routing for consumers using Ecto.Enum (atoms) — previously only string kinds matched, causing Ollama requests to be routed through the OpenAI adapter and fail with HTTP 400.
- **Ollama stream error body drain**: Streaming error responses now drain the `Req.Response.Async` body via `HTTP.drain_async_body/1` to extract the actual error message. Previously logged the opaque `#Req.Response.Async<...>` struct.
- **Ollama stream error logging**: Stream errors now log the status and response body at warning level for debuggability. `require Logger` moved to module top.

### Added

- **Ollama integration tests**: Streaming, system prompt handling, embeddings, and atom-kind compatibility tests.
- **`adapter_for/1` unit tests**: Exhaustive coverage of all format/kind combinations with both atom and string values.

## [0.1.2] - 2026-05-13

### Changed

- **Extracted `Arcanum.HTTP`**: Shared HTTP client (`client/0`), URL construction (`base_url/2`, `base_url_strip_v1/2`), and async body draining (`drain_async_body/1`) — replaces 4 duplicated copies across adapters and Copilot auth.
- **Extracted `Arcanum.Retry`**: Generic retry wrapper (`with_retry/2`) with configurable retriable statuses and exponential backoff (`backoff/1`) — replaces 3 duplicated retry implementations.
- **Extracted `Arcanum.SSE`**: Callback-driven SSE stream parsing (`stream/2`) with configurable done sentinel — replaces duplicated SSE parsing in OpenAI and Anthropic adapters.
- **Bounded async drain**: `drain_async_body/1` now enforces a 10 MB byte limit to prevent unbounded memory consumption.
- **Regression script**: Added `--skip-vision` and `--skip-image-gen` flags to `test/regression.sh`.
- **Makefile**: Added `make regression` target.
- **Unified content blocks**: `Intent.content` and `Response.content` are always `[content_block()]`. Bare string content is no longer accepted — callers must use `Intent.text/1` to wrap text. `Response.text/1` helper extracts text from content blocks.
- **Provider behaviour**: `use Arcanum.Provider` macro replaces `@behaviour` + `@optional_callbacks`. Optional callbacks (`embed/3`, `generate_image/3`, `generate_video/3`) now have `defoverridable` default implementations returning `{:error, :not_supported}`. Adapters override only what they support.
- **Gateway**: Direct adapter dispatch replaces `apply/3` + `function_exported?` runtime detection. No runtime capability checks — capabilities are declared statically at compile time.
- **Image generation body**: `size` and `quality` are now profile-driven — only included in the request when the model's overlay declares `supported_sizes` or `supported_qualities`. Providers that don't support these params (e.g. xAI) no longer receive them.
- **Image response parsing**: `parse_image_blocks` uses `mime_type` from the provider response when available, falling back to the request format. Supports providers (e.g. xAI) that return `mime_type` instead of relying on the request format.
- **Test env vars**: Renamed `ARCANUM_TEST_OPENAI_*` to `ARCANUM_TEST_PROVIDER_*`. These describe a provider (URL, key, model, kind), not specifically OpenAI. `ARCANUM_TEST_PROVIDER_KIND` defaults to `"openai"` and drives overlay resolution.

### Added

- **xAI (Grok) support**: Verified integration with `grok-3-mini` (chat/stream/tools), `grok-4-fast-non-reasoning` (vision), and `grok-imagine-image` (image generation). Overlays for `grok-4-fast-*`, `grok-4.3`, `grok-imagine-image`, `grok-imagine-image-pro`.
- **Overlay system**: Profile-driven image generation params (`supported_qualities`, `supports_style`, `image_response_mode`) with overlays for gpt-image-1, dall-e-3, dall-e-2, grok-imagine-image
- **Media generation**: `MediaIntent` / `MediaResponse` structs and `Gateway.generate_image/3` / `Gateway.generate_video/3` functions
- **ModelProfile fields**: `uses_max_completion_tokens` flag for newer OpenAI models
- **Ollama adapter**: Multimodal (vision) support
- **Resolver**: Generic overlay resolution with nested provider→model map structure
- **Regression test suite**: Data-driven `test/regression.sh` with reusable provider test runners (`run_openai_provider`, `run_anthropic_provider`, `run_ollama_provider`, `run_vision_test`, `run_image_generation_test`). Fail-fast. Providers/models hardcoded — env vars only for API keys. Separate vision and image generation regression runs per provider.
- **CONTRIBUTING.md**: Provider and model integration guide with overlay reference, regression test template, and verification checklist

### Fixed

- **Streaming delta merge**: `merge_content_blocks/2` coalesces consecutive text blocks during streaming
- **Ollama tool calls**: `decode_arguments/1` handles Ollama returning `arguments` as a map instead of a JSON string
- **Copilot test isolation**: `on_exit` cleanup now resets both `:copilot_client_id` and `:http_client` application env to prevent stub leaks into integration tests
- **Usage tracking assertion**: Relaxed `total_tokens == prompt + completion` to `>=` — reasoning models (e.g. xAI grok-3-mini) include `reasoning_tokens` in total but not in completion

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

[Unreleased]: https://github.com/kakilangit/arcanum/compare/v0.1.10...HEAD
[0.1.10]: https://github.com/kakilangit/arcanum/compare/v0.1.9...v0.1.10
[0.1.9]: https://github.com/kakilangit/arcanum/compare/v0.1.8...v0.1.9
[0.1.8]: https://github.com/kakilangit/arcanum/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/kakilangit/arcanum/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/kakilangit/arcanum/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/kakilangit/arcanum/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/kakilangit/arcanum/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/kakilangit/arcanum/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/kakilangit/arcanum/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/kakilangit/arcanum/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/kakilangit/arcanum/releases/tag/v0.1.0
