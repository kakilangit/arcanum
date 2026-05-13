defmodule Arcanum.ModelProfile.Resolver do
  @moduledoc """
  Resolves a `ModelProfile` for a given provider and model.

  Resolution order (highest to lowest priority):
  1. User overrides — caller-provided map of profile fields
  2. Overlay — provider/model-specific fields from `priv/overlays.json`
  3. Registry — models.dev cache (single source of truth for base profiles)
  4. Provider default — weakest fallback for local providers not in models.dev
  5. Global default — unknown everything
  """

  alias Arcanum.ModelProfile
  alias Arcanum.ModelProfile.Registry

  @overlays_path Path.join(:code.priv_dir(:arcanum), "overlays.json")
  @external_resource @overlays_path

  @raw Jason.decode!(File.read!(@overlays_path))

  @valid_keys Map.keys(%ModelProfile{}) -- [:__struct__]

  @overlays @raw["overlays"]
            |> Enum.take(100)
            |> Enum.flat_map(fn {provider, models} ->
              models
              |> Enum.take(200)
              |> Enum.map(fn {model, attrs} ->
                value =
                  attrs
                  |> Enum.take(50)
                  |> Enum.reduce(%{}, fn {k, v}, acc ->
                    key = String.to_existing_atom(k)

                    if key in @valid_keys do
                      coerced =
                        case {key, v} do
                          {:tool_call_format, "xml_text"} -> :xml_text
                          {:tool_call_format, "native"} -> :native
                          {:image_response_mode, "native_b64"} -> :native_b64
                          {:image_response_mode, "request_b64"} -> :request_b64
                          _ -> v
                        end

                      Map.put(acc, key, coerced)
                    else
                      acc
                    end
                  end)

                {{provider, model}, value}
              end)
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

  @doc """
  Returns the profile for a provider kind + model combination.

  Optional `overrides` map takes highest priority over all other sources.
  """
  @spec resolve(String.t(), String.t(), map() | nil) :: ModelProfile.t()
  def resolve(provider_kind, model, overrides \\ nil)
      when is_binary(provider_kind) and is_binary(model) do
    base_profile(provider_kind, model)
    |> apply_overlay(provider_kind, model)
    |> apply_overrides(overrides)
  end

  defp base_profile(provider_kind, model) do
    Registry.lookup(provider_kind, model) || provider_default(provider_kind)
  end

  defp apply_overlay(profile, provider_kind, model) do
    case Map.get(@overlays, {provider_kind, model}) do
      nil -> profile
      overlay -> struct!(profile, overlay)
    end
  end

  defp provider_default(kind) do
    Map.get(@provider_defaults, kind, ModelProfile.default())
  end

  defp apply_overrides(profile, nil), do: profile
  defp apply_overrides(profile, overrides) when overrides == %{}, do: profile

  defp apply_overrides(profile, overrides) when is_map(overrides) do
    valid_keys = Map.keys(%ModelProfile{})

    attrs =
      overrides
      |> Enum.filter(fn {k, _v} -> k in valid_keys end)
      |> Map.new()

    struct!(profile, attrs)
  end
end
