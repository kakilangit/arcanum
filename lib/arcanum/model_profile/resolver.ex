defmodule Arcanum.ModelProfile.Resolver do
  @moduledoc """
  Resolves a `ModelProfile` for a given provider and model.

  Resolution order:
  1. Registry (models.dev cache) — the single source of truth
  2. Overlay merge — provider/model-specific fields from `priv/overlays.json`
     that models.dev doesn't carry (thinking_param, preserve_reasoning, provider_routing)
  3. Provider-level default — weakest fallback for local providers
     not in models.dev (ollama, lmstudio, vllm)
  4. Global default — unknown everything
  """

  alias Arcanum.ModelProfile
  alias Arcanum.ModelProfile.Registry

  @overlays_path Path.join(:code.priv_dir(:arcanum), "overlays.json")
  @external_resource @overlays_path

  @raw Jason.decode!(File.read!(@overlays_path))

  @overlays @raw["overlays"]
            |> Enum.take(100)
            |> Enum.map(fn entry ->
              key = {entry["provider"], entry["model"]}

              value =
                entry
                |> Map.drop(["provider", "model"])
                |> Enum.reduce(%{}, fn
                  {"thinking_param", v}, acc -> Map.put(acc, :thinking_param, v)
                  {"preserve_reasoning", v}, acc -> Map.put(acc, :preserve_reasoning, v)
                  {"provider_routing", v}, acc -> Map.put(acc, :provider_routing, v)
                  _other, acc -> acc
                end)

              {key, value}
            end)
            |> Map.new()

  @provider_defaults @raw["provider_defaults"]
                     |> Enum.take(50)
                     |> Enum.map(fn {kind, attrs} ->
                       profile = %ModelProfile{
                         supports_system_role: Map.get(attrs, "supports_system_role", true),
                         supports_tools: Map.get(attrs, "supports_tools", true),
                         tool_call_format:
                           case Map.get(attrs, "tool_call_format", "native") do
                             "xml_text" -> :xml_text
                             _ -> :native
                           end,
                         reasoning_field: nil,
                         max_context: Map.get(attrs, "max_context")
                       }

                       {kind, profile}
                     end)
                     |> Map.new()

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

  defp apply_overlay(profile, provider_kind, model) do
    case Map.get(@overlays, {provider_kind, model}) do
      nil -> profile
      overlay -> struct!(profile, overlay)
    end
  end

  # -------------------------------------------------------------------
  # Provider-level defaults (local providers not in models.dev)
  # -------------------------------------------------------------------

  defp provider_default(kind) do
    Map.get(@provider_defaults, kind, ModelProfile.default())
  end
end
