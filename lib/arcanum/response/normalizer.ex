defmodule Arcanum.Response.Normalizer do
  @moduledoc """
  Profile-driven post-processing of inference responses.

  The adapter translates the wire format faithfully.
  This module applies model-specific normalization based on the profile:

  - Content fallback from thinking (reasoning models with empty content)
  - Malformed tool-call filtering (models that emit incomplete tool calls)
  - XML text tool-call extraction (models that emit tool calls as text)
  - Streaming delta normalization

  All model-specific behavior lives here — not in the adapter.
  """

  require Logger

  alias Arcanum.{ModelProfile, Response}

  @xml_tool_call_regex ~r/<tool_call>\s*<function=([^>]+)>\s*(.*?)\s*<\/function>\s*<\/tool_call>/s
  @xml_param_regex ~r/<parameter=([^>]+)>\s*(.*?)\s*<\/parameter>/s
  @max_xml_params 50

  @doc """
  Normalizes a complete (non-streaming) response based on the model profile.
  """
  @spec normalize(Response.t(), ModelProfile.t()) :: Response.t()
  def normalize(%Response{} = response, %ModelProfile{} = profile) do
    response
    |> apply_content_fallback(profile)
    |> filter_malformed_tool_calls()
    |> apply_tool_call_extraction(profile)
  end

  @doc """
  Normalizes a streaming delta based on the model profile.
  Only applies content fallback (tool calls are extracted from the final merged response).
  """
  @spec normalize_delta(Response.t(), ModelProfile.t()) :: Response.t()
  def normalize_delta(%Response{} = delta, %ModelProfile{} = profile) do
    apply_content_fallback(delta, profile)
  end

  # -------------------------------------------------------------------
  # Content fallback: reasoning models put output in thinking, not content
  # -------------------------------------------------------------------

  defp apply_content_fallback(response, %{reasoning_field: nil}), do: response

  defp apply_content_fallback(%{content: nil, thinking: thinking} = response, profile)
       when is_binary(thinking) and thinking != "" do
    Logger.debug(
      "Normalizer: content fallback from thinking " <>
        "(reasoning_field=#{profile.reasoning_field}, content=nil, thinking=#{byte_size(thinking)}B)"
    )

    %{response | content: thinking}
  end

  defp apply_content_fallback(%{content: "", thinking: thinking} = response, profile)
       when is_binary(thinking) and thinking != "" do
    Logger.debug(
      "Normalizer: content fallback from thinking " <>
        "(reasoning_field=#{profile.reasoning_field}, content=\"\", thinking=#{byte_size(thinking)}B)"
    )

    %{response | content: thinking}
  end

  defp apply_content_fallback(response, _profile), do: response

  # -------------------------------------------------------------------
  # Malformed tool-call filtering
  # -------------------------------------------------------------------

  defp filter_malformed_tool_calls(%{tool_calls: nil} = response), do: response
  defp filter_malformed_tool_calls(%{tool_calls: []} = response), do: response

  defp filter_malformed_tool_calls(%{tool_calls: tool_calls} = response) do
    {valid, invalid} = Enum.split_with(tool_calls, &valid_tool_call?/1)

    if invalid != [] do
      Logger.warning(
        "Normalizer: filtered #{length(invalid)} malformed tool call(s) " <>
          "(#{length(valid)} valid remaining): #{inspect_invalid(invalid)}"
      )
    end

    case valid do
      [] -> %{response | tool_calls: nil}
      calls -> %{response | tool_calls: calls}
    end
  end

  defp valid_tool_call?(%{function: %{name: name}})
       when is_binary(name) and name != "" do
    true
  end

  defp valid_tool_call?(_), do: false

  defp inspect_invalid(invalid) do
    invalid
    |> Enum.take(5)
    |> Enum.map_join(", ", fn
      %{id: id, function: %{name: name}} -> "id=#{inspect(id)} name=#{inspect(name)}"
      other -> inspect(other)
    end)
  end

  # -------------------------------------------------------------------
  # XML text tool-call extraction
  # -------------------------------------------------------------------

  defp apply_tool_call_extraction(response, %{tool_call_format: :native}), do: response

  defp apply_tool_call_extraction(response, %{tool_call_format: :xml_text}) do
    # If native tool_calls are already present, use them
    case response.tool_calls do
      calls when is_list(calls) and calls != [] ->
        Logger.debug(
          "Normalizer: skipping XML extraction, #{length(calls)} native tool call(s) present"
        )

        response

      _ ->
        case parse_xml_tool_calls(response.content) do
          nil ->
            Logger.debug("Normalizer: no XML tool calls found in content")
            response

          calls ->
            Logger.info(
              "Normalizer: extracted #{length(calls)} XML tool call(s) from content " <>
                "(format=xml_text)"
            )

            %{response | tool_calls: calls}
        end
    end
  end

  defp parse_xml_tool_calls(nil), do: nil
  defp parse_xml_tool_calls(""), do: nil

  defp parse_xml_tool_calls(content) when is_binary(content) do
    case Regex.scan(@xml_tool_call_regex, content) do
      [] -> nil
      matches -> Enum.map(matches, &parse_xml_match/1)
    end
  end

  defp parse_xml_match([_full, name, params_str]) do
    params =
      @xml_param_regex
      |> Regex.scan(params_str)
      |> Enum.take(@max_xml_params)
      |> Map.new(fn [_, key, value] -> {key, value} end)

    %{
      id: "xmlcall_#{:erlang.unique_integer([:positive])}",
      function: %{
        name: name,
        arguments: Jason.encode!(params)
      }
    }
  end
end
