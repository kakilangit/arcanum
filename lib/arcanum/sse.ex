defmodule Arcanum.SSE do
  @moduledoc """
  Shared Server-Sent Events parsing for Arcanum adapters.

  Provides the common SSE stream transform and chunk/line parsing.
  Adapters supply their own event-to-delta conversion via a callback.
  """

  @doc """
  Transforms a raw SSE stream into a stream of parsed events.

  Each chunk is split into SSE lines. Lines matching `"data: "` prefix
  are JSON-decoded and passed to `parse_event_fn`. The stream halts
  when `parse_event_fn` returns `:done` or the `done_sentinel` is encountered.

  ## Options

  - `:parse_event` — `fn json_map -> {:data, delta} | :done | :skip` (required)
  - `:done_sentinel` — string that signals end of stream (e.g. `"[DONE]"`), optional
  """
  @spec stream(Enumerable.t(), keyword()) :: Enumerable.t()
  def stream(raw_stream, opts) do
    parse_event = Keyword.fetch!(opts, :parse_event)
    done_sentinel = Keyword.get(opts, :done_sentinel)

    Stream.transform(raw_stream, :cont, fn
      chunk, :cont ->
        events = parse_chunk(chunk, parse_event, done_sentinel)

        case Enum.find(events, &match?(:done, &1)) do
          :done -> {events, :done}
          nil -> {events, :cont}
        end

      _chunk, :done ->
        {:halt, :done}
    end)
  end

  @doc """
  Parses a single SSE chunk into a list of events.
  """
  @spec parse_chunk(term(), (map() -> term()), String.t() | nil) :: list()
  def parse_chunk(chunk, parse_event, done_sentinel) when is_binary(chunk) do
    chunk
    |> String.split("\n")
    |> Enum.flat_map(&parse_line(&1, parse_event, done_sentinel))
  end

  def parse_chunk(%{data: data}, parse_event, done_sentinel),
    do: parse_chunk(data, parse_event, done_sentinel)

  def parse_chunk(_, _parse_event, _done_sentinel), do: []

  defp parse_line("data: " <> rest, parse_event, done_sentinel) do
    trimmed = String.trim(rest)

    if done_sentinel && trimmed == done_sentinel do
      [:done]
    else
      decode_and_process(trimmed, parse_event)
    end
  end

  defp parse_line(_, _parse_event, _done_sentinel), do: []

  defp decode_and_process(json, parse_event) do
    case Jason.decode(json) do
      {:ok, body} -> wrap_event(parse_event.(body))
      {:error, _} -> []
    end
  end

  defp wrap_event(:skip), do: []
  defp wrap_event(:done), do: [:done]
  defp wrap_event(event), do: [event]
end
