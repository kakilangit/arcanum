# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

### Changed

- **README**: Remove untested providers (OpenAI, Anthropic, xAI, Ollama, vLLM) from supported list — code retained, documentation narrowed to verified providers
- **README**: Update installation version to `~> 0.1.0`

## [0.1.0] - 2026-05-12

### Added

- **Gateway API**: Single entry point (`Arcanum.Gateway`) for chat, streaming, embeddings, and model listing across all providers
- **Provider adapters**: OpenAI, Anthropic, and Ollama adapters with unified request/response normalization
- **OpenAI-compatible providers**: DeepSeek, GitHub Copilot, OpenRouter, xAI (Grok), Z.AI/Zhipu, LM Studio, vLLM — all route through the OpenAI adapter
- **Streaming support**: Chunked SSE streaming with delta merging for content and tool calls
- **Tool use**: Native, XML-text, and JSON-text tool call formats, transparently selected per model profile
- **Model Profile Registry**: ETS-cached model capabilities from [models.dev](https://models.dev), refreshed hourly with bounded retry
- **Profile-driven normalization**: `Arcanum.Response.Normalizer` handles content fallback, think-tag stripping, reasoning extraction, and tool call parsing based on declared model capabilities
- **Overlay system**: `priv/overlays.json` for provider/model-specific overrides (thinking_param, preserve_reasoning, provider_routing) not covered by models.dev
- **Provider-level defaults**: Fallback profiles for local providers (Ollama, LM Studio, vLLM) when models aren't in the registry
- **GitHub Copilot auth**: OAuth device code flow (RFC 8628) with token caching and automatic refresh
- **LM Studio model loading**: `Arcanum.EnsureModel` pre-loads models before inference with bounded polling
- **Local provider probing**: `Arcanum.Probe` TCP availability check for Ollama/LM Studio/vLLM
- **Structured errors**: Two-layer error tuples (`{:error, {:api_error, status, body}}`) — no opaque structs leak across boundaries
- **Bounded everything**: Retries, timeouts, poll attempts, model counts, registry refresh — all have explicit upper limits
- **README**: Full library overview, usage examples, architecture diagram, and design principles

### Fixed

- **Streaming tool call merge**: Separate `parse_tool_call_deltas/1` preserves `index` field and defaults arguments to `""` for proper concatenation across delta fragments
- **Async body drain**: Streaming errors drain the `Req.Response.Async` body at the adapter layer — callers never receive opaque structs
- **Base URL handling**: Strips trailing `/v1` before appending API paths, correctly handles versioned paths (Z.AI `/v4`)

[Unreleased]: https://github.com/kakilangit/arcanum/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/kakilangit/arcanum/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/kakilangit/arcanum/releases/tag/v0.1.0
