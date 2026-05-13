defmodule Arcanum.HTTP do
  @moduledoc """
  Shared HTTP utilities for Arcanum adapters.

  Centralizes the configurable HTTP client, URL construction,
  and async response body draining.
  """

  @max_drain_bytes 10 * 1024 * 1024

  @doc """
  Returns the configured HTTP client module (defaults to `Req`).
  """
  @spec client() :: module()
  def client do
    Application.get_env(:arcanum, :http_client, Req)
  end

  @doc """
  Builds a full URL from a provider's `base_url` and a path.

  Trims trailing `/` from the base URL before appending.
  """
  @spec base_url(map(), String.t()) :: String.t()
  def base_url(provider, path) do
    provider.base_url
    |> String.trim_trailing("/")
    |> Kernel.<>(path)
  end

  @doc """
  Builds a full URL from a provider's `base_url` and a path,
  also stripping a trailing `/v1` segment. Used by Anthropic
  which appends its own `/v1/messages` path.
  """
  @spec base_url_strip_v1(map(), String.t()) :: String.t()
  def base_url_strip_v1(provider, path) do
    provider.base_url
    |> String.trim_trailing("/")
    |> String.trim_trailing("/v1")
    |> Kernel.<>(path)
  end

  @doc """
  Drains a `Req.Response.Async` body into a decoded map or raw binary.

  Enforces a #{div(@max_drain_bytes, 1024 * 1024)} MB byte limit to prevent
  unbounded memory consumption. Returns `nil` on any error.

  Passes non-async bodies through unchanged.
  """
  @spec drain_async_body(term()) :: term()
  def drain_async_body(%Req.Response.Async{} = async) do
    raw =
      async
      |> Stream.transform(0, fn chunk, acc ->
        chunk_bin = IO.iodata_to_binary(List.wrap(chunk))
        new_acc = acc + byte_size(chunk_bin)

        if new_acc > @max_drain_bytes do
          {:halt, new_acc}
        else
          {[chunk_bin], new_acc}
        end
      end)
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    case Jason.decode(raw) do
      {:ok, decoded} -> decoded
      _ -> raw
    end
  rescue
    _ -> nil
  end

  def drain_async_body(body), do: body
end
