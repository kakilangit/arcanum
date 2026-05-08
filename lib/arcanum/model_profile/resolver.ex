defmodule Arcanum.ModelProfile.Resolver do
  @moduledoc """
  Resolves a `ModelProfile` for a given provider and model.

  Resolution order:
  1. Exact model match in known profiles
  2. Provider-level default
  3. Global default (weakest assumptions)

  This replaces all runtime capability detection (422 retry, regex fallback).
  Adding support for a new model = adding an entry here.
  """

  alias Arcanum.ModelProfile
  alias Arcanum.ModelProfile.Registry

  @max_profiles 1_000

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Returns the profile for a provider kind + model combination.

  Resolution order:
  1. Exact model match in hardcoded profiles
  2. models.dev registry cache (ETS)
  3. Provider-level default
  4. Global default (weakest assumptions)
  """
  @spec resolve(String.t(), String.t()) :: ModelProfile.t()
  def resolve(provider_kind, model) when is_binary(provider_kind) and is_binary(model) do
    model_profiles()[model] ||
      Registry.lookup(provider_kind, model) ||
      provider_default(provider_kind)
  end

  # -------------------------------------------------------------------
  # Provider-level defaults
  # -------------------------------------------------------------------

  defp provider_default("openai"), do: ModelProfile.capable()
  defp provider_default("anthropic"), do: anthropic_profile()
  defp provider_default("ollama"), do: ollama_profile()
  defp provider_default("lmstudio"), do: ollama_profile()
  defp provider_default("vllm"), do: vllm_profile()

  defp provider_default("openrouter") do
    # OpenRouter exposes an OpenAI-compatible API for all models —
    # system role and native tool calls are always supported at the
    # API level regardless of the underlying model.
    %ModelProfile{
      supports_system_role: true,
      supports_tools: true,
      tool_call_format: :native,
      reasoning_field: :reasoning_content,
      provider_routing: %{route: "fallback", require: ["tools"]}
    }
  end

  defp provider_default("deepseek") do
    %ModelProfile{
      supports_system_role: true,
      supports_tools: true,
      tool_call_format: :native,
      reasoning_field: :reasoning_content
    }
  end

  defp provider_default("xai") do
    %ModelProfile{
      supports_system_role: true,
      supports_tools: true,
      tool_call_format: :native,
      reasoning_field: nil
    }
  end

  defp provider_default("zai") do
    %ModelProfile{
      supports_system_role: true,
      supports_tools: true,
      tool_call_format: :native,
      reasoning_field: :reasoning_content
    }
  end

  defp provider_default("zhipuai"), do: provider_default("zai")

  defp provider_default(_unknown), do: ModelProfile.default()

  # -------------------------------------------------------------------
  # Provider profile helpers
  # -------------------------------------------------------------------

  defp anthropic_profile do
    %ModelProfile{
      supports_system_role: true,
      supports_tools: true,
      tool_call_format: :native,
      reasoning_field: nil
    }
  end

  defp ollama_profile do
    %ModelProfile{
      supports_system_role: true,
      supports_tools: false,
      tool_call_format: :xml_text,
      reasoning_field: nil,
      max_context: 32_768
    }
  end

  defp vllm_profile do
    %ModelProfile{
      supports_system_role: true,
      supports_tools: true,
      tool_call_format: :native,
      reasoning_field: nil
    }
  end

  defp zai_no_interleave do
    %ModelProfile{
      supports_system_role: true,
      supports_tools: true,
      tool_call_format: :native,
      reasoning_field: nil
    }
  end

  # -------------------------------------------------------------------
  # Known model overrides (exact match)
  # Capped at @max_profiles entries to enforce bounded collections.
  # -------------------------------------------------------------------

  defp model_profiles do
    profiles = %{
      # OpenRouter free-tier models (weak, XML tool calls)
      "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free" => %ModelProfile{
        supports_system_role: false,
        supports_tools: false,
        tool_call_format: :xml_text,
        reasoning_field: :reasoning_content,
        max_context: 131_072,
        provider_routing: %{route: "fallback", require: ["tools"]}
      },
      "deepseek/deepseek-chat-v3-0324:free" => %ModelProfile{
        supports_system_role: true,
        supports_tools: true,
        tool_call_format: :native,
        reasoning_field: nil,
        provider_routing: %{route: "fallback", require: ["tools"]}
      },
      "google/gemini-2.5-flash-preview:thinking" => %ModelProfile{
        supports_system_role: true,
        supports_tools: true,
        tool_call_format: :native,
        reasoning_field: nil,
        provider_routing: %{route: "fallback", require: ["tools"]}
      },
      # OpenAI native
      "gpt-4o" => ModelProfile.capable(),
      "gpt-4o-mini" => ModelProfile.capable(),
      "gpt-4.1" => ModelProfile.capable(),
      "gpt-4.1-mini" => ModelProfile.capable(),
      "gpt-4.1-nano" => ModelProfile.capable(),
      "o3" => %ModelProfile{ModelProfile.capable() | reasoning_field: :reasoning_content},
      "o3-mini" => %ModelProfile{ModelProfile.capable() | reasoning_field: :reasoning_content},
      "o4-mini" => %ModelProfile{ModelProfile.capable() | reasoning_field: :reasoning_content},
      # Anthropic native
      "claude-sonnet-4-20250514" => ModelProfile.capable(),
      "claude-3-5-sonnet-20241022" => ModelProfile.capable(),
      "claude-3-5-haiku-20241022" => ModelProfile.capable(),
      # DeepSeek native
      "deepseek-chat" => %ModelProfile{
        supports_system_role: true,
        supports_tools: true,
        tool_call_format: :native,
        reasoning_field: :reasoning_content
      },
      "deepseek-reasoner" => %ModelProfile{
        supports_system_role: true,
        supports_tools: false,
        tool_call_format: :xml_text,
        reasoning_field: :reasoning_content
      },
      # Z.AI / Zhipu GLM — older models without interleaved reasoning
      "glm-4.5" => zai_no_interleave(),
      "glm-4.5v" => zai_no_interleave(),
      "glm-4.5-flash" => zai_no_interleave(),
      "glm-4.5-air" => zai_no_interleave(),
      "glm-4.6" => zai_no_interleave(),
      "glm-4.6v" => zai_no_interleave()
    }

    # Enforce bounded collection
    Map.take(profiles, profiles |> Map.keys() |> Enum.take(@max_profiles))
  end
end
