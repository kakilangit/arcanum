defmodule Arcanum.Probe do
  @moduledoc """
  Probes inference providers to determine availability.

  Uses a lightweight TCP connect to check if the provider's host is
  reachable, avoiding repeated API calls that can trigger model reloads
  in local providers.
  """

  @probe_timeout 2_000

  @doc """
  Probes a provider and returns its status.

  Cloud providers are always considered `:online` (failures are detected
  at request time). Local and custom providers are probed by attempting
  a TCP connection to their host and port.
  """
  @spec probe_provider(map()) :: :online | :offline
  def probe_provider(%{type: :cloud}), do: :online
  def probe_provider(%{api_format: format}) when format in [:grimoire, "grimoire"], do: :online

  def probe_provider(provider) do
    case parse_host_port(provider.base_url) do
      {:ok, host, port} ->
        case :gen_tcp.connect(host, port, [], @probe_timeout) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            :online

          {:error, _} ->
            :offline
        end

      :error ->
        :offline
    end
  end

  defp parse_host_port(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, port: port} when is_binary(host) and is_integer(port) ->
        {:ok, String.to_charlist(host), port}

      %URI{host: host, scheme: "https"} when is_binary(host) ->
        {:ok, String.to_charlist(host), 443}

      %URI{host: host, scheme: "http"} when is_binary(host) ->
        {:ok, String.to_charlist(host), 80}

      _ ->
        :error
    end
  end

  defp parse_host_port(_), do: :error
end
