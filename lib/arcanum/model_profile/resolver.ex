defmodule Arcanum.ModelProfile.Resolver do
  @moduledoc """
  Resolves a `ModelProfile` for a given provider and model.

  Resolution order:
  1. Registry (models.dev cache) — the single source of truth
  2. Overlay merge — provider/model-specific fields that models.dev
     doesn't carry (thinking_param, preserve_reasoning, provider_routing)
  3. Provider-level default — weakest fallback for local providers
     not in models.dev (ollama, vllm)
  4. Global default — unknown everything

  Adding support for a new model = adding it to models.dev.
  """

  alias Arcanum.ModelProfile
  alias Arcanum.ModelProfile.Registry

  @max_overlays 100

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Returns the profile for a provider kind + model combination.
  """
  @spec resolve(String.t(), String.t()) :: ModelProfile.t()
  def resolve(provider_kind, model) when is_binary(provider_kind) and is_binary(model) do
    case Registry.lookup(provider_kind, model) do
      %ModelProfile{} = profile ->
        apply_overlay(profile, provider_kind, model)

      nil ->
        provider_default(provider_kind)
    end
  end

  # -------------------------------------------------------------------
  # Overlay — fields models.dev doesn't carry
  # -------------------------------------------------------------------

  # Overlays are sparse maps merged on top of a Registry profile.
  # Only fields that models.dev cannot express belong here.
  # Capped at @max_overlays entries.
  defp overlays do
    map = %{
      # ZAI interleaved thinking models need explicit thinking param
      {"zai", "glm-4.7"} => %{thinking_param: %{"type" => "enabled"}, preserve_reasoning: true},
      {"zai", "glm-5"} => %{thinking_param: %{"type" => "enabled"}, preserve_reasoning: true},
      {"zai", "glm-5.1"} => %{thinking_param: %{"type" => "enabled"}, preserve_reasoning: true},
      {"zai", "glm-5v-turbo"} => %{
        thinking_param: %{"type" => "enabled"},
        preserve_reasoning: true
      },
      {"zhipuai", "glm-4.7"} => %{
        thinking_param: %{"type" => "enabled"},
        preserve_reasoning: true
      },
      {"zhipuai", "glm-5"} => %{
        thinking_param: %{"type" => "enabled"},
        preserve_reasoning: true
      },
      {"zhipuai", "glm-5.1"} => %{
        thinking_param: %{"type" => "enabled"},
        preserve_reasoning: true
      }
    }

    Map.take(map, map |> Map.keys() |> Enum.take(@max_overlays))
  end

  defp apply_overlay(profile, provider_kind, model) do
    case Map.get(overlays(), {provider_kind, model}) do
      nil -> profile
      overlay -> struct!(profile, overlay)
    end
  end

  # -------------------------------------------------------------------
  # Provider-level defaults (local providers not in models.dev)
  # -------------------------------------------------------------------

  defp provider_default("ollama"), do: local_profile()
  defp provider_default("lmstudio"), do: local_profile()
  defp provider_default("vllm"), do: vllm_profile()
  defp provider_default(_unknown), do: ModelProfile.default()

  defp local_profile do
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
end
