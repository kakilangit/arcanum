defmodule Arcanum.Response.Normalizer do
  @moduledoc """
  Profile-driven post-processing of inference responses.

  The adapter translates the wire format faithfully.
  This module applies model-specific normalization based on the profile:

  - Content fallback from thinking (reasoning models with empty content)
  - Think tag stripping (DeepSeek, GLM embed reasoning in `<think>` tags)
  - Malformed tool-call filtering (models that emit incomplete tool calls)
  - XML text tool-call extraction (models that emit tool calls as text)
  - JSON code-block tool-call extraction (last-resort fallback)
  - Streaming delta normalization

  All model-specific behavior lives here — not in the adapter.
  """

  require Logger

  alias Arcanum.{ModelProfile, Response}

  @xml_tool_call_regex ~r/<tool_call>\s*<function=([^>]+)>\s*(.*?)\s*<\/function>\s*<\/tool_call>/s
  @xml_param_regex ~r/<parameter=([^>]+)>\s*(.*?)\s*<\/parameter>/s
  @think_tag_regex ~r/<think>.*?<\/think>\s*/s
  @dangling_think_regex ~r/<\/?think>\s*/
  @json_tool_call_regex ~r/```(?:json)?\s*(\{[^`]+\})\s*```/s
  @max_xml_params 50

  @doc """
  Normalizes a complete (non-streaming) response based on the model profile.

  Applied in order: content fallback → think tag strip → malformed filter →
  XML extraction → JSON extraction.
  """
  @spec normalize(Response.t(), ModelProfile.t()) :: Response.t()
  def normalize(%Response{} = response, %ModelProfile{} = profile) do
    response
    |> apply_content_fallback(profile)
    |> strip_think_tags()
    |> filter_malformed_tool_calls()
    |> apply_tool_call_extraction(profile)
    |> apply_json_tool_call_extraction()
  end

  @doc """
  Normalizes a streaming delta based on the model profile.

  Only applies content fallback — tool calls are extracted from the final merged response.
  """
  @spec normalize_delta(Response.t(), ModelProfile.t()) :: Response.t()
  def normalize_delta(%Response{} = delta, %ModelProfile{} = profile) do
    apply_content_fallback(delta, profile)
  end

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

  defp strip_think_tags(%{content: nil} = response), do: response
  defp strip_think_tags(%{content: ""} = response), do: response

  defp strip_think_tags(%{content: content} = response) do
    if String.contains?(content, "<think>") || String.contains?(content, "</think>") do
      extracted_thinking =
        @think_tag_regex
        |> Regex.scan(content)
        |> Enum.map_join("\n", fn [match] ->
          match
          |> String.replace(~r/<\/?think>/, "")
          |> String.trim()
        end)

      cleaned =
        content
        |> String.replace(@think_tag_regex, "")
        |> String.replace(@dangling_think_regex, "")
        |> String.trim()

      thinking =
        case {response.thinking, extracted_thinking} do
          {nil, ""} -> nil
          {nil, extracted} -> extracted
          {existing, _} -> existing
        end

      %{response | content: non_blank(cleaned), thinking: thinking}
    else
      response
    end
  end

  defp non_blank(""), do: nil
  defp non_blank(s) when is_binary(s), do: s

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

  defp apply_tool_call_extraction(response, %{tool_call_format: :native}), do: response

  defp apply_tool_call_extraction(response, %{tool_call_format: :xml_text}) do
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

  defp apply_json_tool_call_extraction(%{tool_calls: calls} = response)
       when is_list(calls) and calls != [] do
    response
  end

  defp apply_json_tool_call_extraction(%{content: nil} = response), do: response
  defp apply_json_tool_call_extraction(%{content: ""} = response), do: response

  defp apply_json_tool_call_extraction(%{content: content} = response) do
    case parse_json_tool_calls(content) do
      nil ->
        response

      calls ->
        Logger.info("Normalizer: extracted #{length(calls)} JSON tool call(s) from content")

        %{response | tool_calls: calls}
    end
  end

  defp parse_json_tool_calls(content) do
    @json_tool_call_regex
    |> Regex.scan(content)
    |> Enum.flat_map(&decode_json_tool_call/1)
    |> case do
      [] -> nil
      calls -> calls
    end
  end

  defp decode_json_tool_call([_full, json_str]) do
    case Jason.decode(json_str) do
      {:ok, parsed} -> maybe_build_tool_call(parsed)
      {:error, _} -> []
    end
  end

  defp maybe_build_tool_call(parsed) when is_map(parsed) do
    name = parsed["tool"] || parsed["name"] || parsed["function"]
    args = parsed["params"] || parsed["arguments"] || parsed["parameters"] || %{}

    if is_binary(name) and name != "" do
      [
        %{
          id: "jsoncall_#{:erlang.unique_integer([:positive])}",
          function: %{
            name: name,
            arguments: if(is_binary(args), do: args, else: Jason.encode!(args))
          }
        }
      ]
    else
      []
    end
  end

  defp maybe_build_tool_call(_), do: []
end
